# cython: language_level=3, embedsignature=True
import asyncio
import collections
import sys

cimport cython
from libc.stdint cimport uint32_t, uint64_t
from libc.string cimport memset
from cpython cimport PyThread_get_thread_ident, Py_INCREF, Py_DECREF

from .includes.python cimport PY_VERSION_HEX
from .includes.hv cimport *
from .handle cimport TimerHandle
from .transport cimport HVSocketTransport, DatagramTransport
from .server cimport Server
import asyncio
import threading

cdef aio_Future = asyncio.Future
cdef aio_ensure_future = asyncio.ensure_future
cdef aio_isfuture = asyncio.isfuture
cdef aio_Handle = asyncio.Handle
cdef aio_set_running_loop = asyncio._set_running_loop
cdef col_deque = collections.deque

include "includes/consts.pxi"

cdef:
    uint32_t INFINITE = <uint32_t>-1


cdef void on_idle(hv.hidle_t* idle) noexcept nogil:
    with gil:
        cdef Loop loop = <Loop>(<hv.hevent_t*>idle).userdata
        if loop is None:
            return
        # run ready callbacks
        while loop._ready:
            try:
                handle = loop._ready.popleft()
            except Exception:
                break
            try:
                handle._run()
            except BaseException:
                # delegate to loop exception handler
                context = {
                    'message': 'Exception in scheduled callback',
                    'handle': handle,
                }
                loop.call_exception_handler(context)
        if loop._stopping:
            hloop_stop((<hv.hevent_t*>idle).loop)
            # delete this idle watcher once stop requested
            hv.hidle_del(idle)


@cython.no_gc_clear
cdef class Loop:
    """Simplified hvloop event loop"""

    def __cinit__(self):
        self.hvloop = hv.hloop_new(0)
        self._debug = 0
        self._thread_id = 0
        self._closed = 0
        self._stopping = 0
        self._ready = col_deque()
        self._timers = set()
        self._exception_handler = None
        self._default_executor = None

    def __init__(self):
        pass

    def __dealloc__(self):
        if self.hvloop != NULL:
            hv.hloop_free(&self.hvloop)

    def __repr__(self):
        return '<{} running={} closed={} debug={}>'.format(
            'hvloop.Loop', self.is_running(), self.is_closed(), self.get_debug()
        )

    # Basic loop control
    cdef _run(self, int flags):
        Py_INCREF(self)
        aio_set_running_loop(self)
        self._thread_id = PyThread_get_thread_ident()

        cdef int err
        err = hv.hloop_run(self.hvloop)

        Py_DECREF(self)

        self._stopping = 0
        self._thread_id = 0
        if err < 0:
            raise ValueError("loop run error")

    def run_forever(self):
        cdef hv.hidle_t* idle
        idle = hv.hidle_add(self.hvloop, on_idle, INFINITE)
        hv.hevent_set_userdata(<hv.hevent_t*>idle, <void*>self)
        return self._run(1)

    def run_until_complete(self, future):
        future = aio_ensure_future(future, loop=self)

        def _run_until_complete_cb(fut):
            if not fut.cancelled():
                exc = fut.exception()
                if isinstance(exc, (SystemExit, KeyboardInterrupt)):
                    return
            self.stop()

        future.add_done_callback(_run_until_complete_cb)
        try:
            self.run_forever()
        except:
            if future.done() and not future.cancelled():
                future.exception()
            raise
        finally:
            future.remove_done_callback(_run_until_complete_cb)

        if not future.done():
            raise RuntimeError('Event loop stopped before Future completed.')

        return future.result()

    def stop(self):
        """Stop running the event loop"""
        self._stopping = 1
        # Ensure loop breaks out of run by waking it up
        self._wakeup()

    def is_running(self):
        return (self._thread_id != 0)

    def close(self):
        """Close the event loop"""
        if self.is_running():
            raise RuntimeError("Cannot close a running event loop")
        if self._closed:
            return
        self._closed = 1
        self._ready.clear()
        # free underlying hv loop
        if self.hvloop != NULL:
            hv.hloop_free(&self.hvloop)
            self.hvloop = NULL

    def is_closed(self):
        return self._closed

    # Basic callbacks
    def call_soon(self, callback, *args, context=None):
        handle = aio_Handle(callback, args, self, context)
        self._ready.append(handle)
        # ensure the loop wakes to process ready queue
        self._wakeup()
        return handle

    cdef uint64_t _time(self):
        hv.hloop_update_time(self.hvloop)
        return hv.hloop_now_us(self.hvloop)

    def time(self):
        # return seconds as float per asyncio contract
        return self._time() / 1000000.0

    def create_future(self):
        return aio_Future(loop=self)

    # Scheduling delayed callbacks
    def call_later(self, delay, callback, *args, context=None):
        if delay < 0:
            delay = 0
        # TimerHandle expects milliseconds
        ms = <uint32_t>(delay * 1000.0)
        return TimerHandle(self, callback, args, ms, context)

    def call_at(self, when, callback, *args, context=None):
        now = self.time()
        delay = when - now
        if delay < 0:
            delay = 0
        return self.call_later(delay, callback, *args, context=context)

    # Thread-safe scheduling
    def call_soon_threadsafe(self, callback, *args, context=None):
        handle = aio_Handle(callback, args, self, context)
        self._ready.append(handle)
        self._wakeup()
        return handle

    cdef _wakeup(self):
        # Posting an event to make sure idle runs promptly
        cdef hv.hidle_t* idle = hv.hidle_add(self.hvloop, on_idle, 1)
        hv.hevent_set_userdata(<hv.hevent_t*>idle, <void*>self)

    cdef _make_hio_transport(self, hv.hio_t* io, object protocol, object waiter, object extra, object server):
        cdef HVSocketTransport tr = HVSocketTransport(self, protocol, waiter, extra, server)
        tr._init_hio(io)
        return tr

    # Debug mode
    def get_debug(self):
        return self._debug

    def set_debug(self, enabled):
        self._debug = bool(enabled)

    # Exception handling API
    def set_exception_handler(self, handler):
        self._exception_handler = handler

    def default_exception_handler(self, context):
        try:
            exc = context.get('exception')
            msg = context.get('message')
            if msg is None:
                msg = 'Unhandled exception in event loop'
            if exc is not None:
                sys.stderr.write(f"{msg}: {exc}\n")
            else:
                sys.stderr.write(f"{msg}\n")
        except Exception:
            pass

    def call_exception_handler(self, context):
        handler = self._exception_handler
        if handler is None:
            self.default_exception_handler(context)
            return
        try:
            handler(self, context)
        except Exception:
            self.default_exception_handler(context)

    # Tasks
    def create_task(self, coro):
        return asyncio.create_task(coro)

    # Executors
    def run_in_executor(self, executor, func, *args):
        return asyncio.get_running_loop().run_in_executor(executor, func, *args)

    async def shutdown_default_executor(self, timeout=None):
        # asyncio.run() 会处理默认执行器，这里仅为低层兼容
        # Python 3.12: 接受 timeout；无法直接访问私有执行器，这里调用标准 loop 的实现
        try:
            loop = asyncio.get_running_loop()
            await loop.shutdown_default_executor(timeout=timeout)
        except AttributeError:
            return

    # Async context manager for tests
    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        self.close()

    # Unimplemented FD watching stubs
    def add_reader(self, fd, callback, *args):
        raise NotImplementedError('add_reader is not implemented on hvloop yet')

    def add_writer(self, fd, callback, *args):
        raise NotImplementedError('add_writer is not implemented on hvloop yet')

    def remove_reader(self, fd):
        raise NotImplementedError('remove_reader is not implemented on hvloop yet')

    def remove_writer(self, fd):
        raise NotImplementedError('remove_writer is not implemented on hvloop yet')

    # Networking APIs (TCP/UDP/Server)
    async def create_connection(self, protocol_factory, host=None, port=None, *,
                                ssl=None, family=0, proto=0, flags=0, sock=None,
                                local_addr=None, server_hostname=None, ssl_handshake_timeout=None):
        waiter = self.create_future()
        protocol = protocol_factory()
        if sock is not None:
            # adopt existing connected socket
            fd = sock.fileno()
            cdef hv.hio_t* io = hv.hio_get(self.hvloop, <int>fd)
            if io == NULL:
                raise RuntimeError('failed to adopt socket into hvloop')
            tr = HVSocketTransport(self, protocol, waiter, None, None)
            tr._init_hio(io)
            tr._on_connect()
            await waiter
            return tr, protocol

        if host is None or port is None:
            raise ValueError('host and port are required')
        tr = HVSocketTransport.connect(self, host.encode('utf-8'), <int>port,
                                       protocol, waiter, None, None)
        await waiter
        return tr, protocol

    async def create_server(self, protocol_factory, host=None, port=None, *,
                            family=0, flags=0, sock=None, backlog=100,
                            ssl=None, reuse_address=None, reuse_port=None,
                            ssl_handshake_timeout=None, start_serving=True):
        if sock is not None:
            raise NotImplementedError('sock= is not supported yet')
        if host is None or port is None:
            raise ValueError('host and port are required')
        s = __import__('socket').socket(__import__('socket').AF_INET, __import__('socket').SOCK_STREAM)
        s.setblocking(False)
        s.setsockopt(__import__('socket').SOL_SOCKET, __import__('socket').SO_REUSEADDR, 1)
        s.bind((host, port))
        server = Server(self, [s], protocol_factory, ssl, int(backlog), ssl_handshake_timeout)
        if start_serving:
            await server.start_serving()
        return server

    async def create_datagram_endpoint(self, protocol_factory, local_addr=None, remote_addr=None, *,
                                       family=0, proto=0, flags=0, reuse_address=None,
                                       reuse_port=None, allow_broadcast=None, sock=None):
        if sock is not None:
            raise NotImplementedError('sock= is not supported yet')
        proto_obj = protocol_factory()
        waiter = self.create_future()

        if local_addr is not None and remote_addr is None:
            # UDP server
            hio = hv.hloop_create_udp_server(self.hvloop, local_addr[0].encode('utf-8'), <int>local_addr[1])
            if hio == NULL:
                raise RuntimeError('failed to create udp server')
            dt = DatagramTransport(self, proto_obj, None, waiter, None)
            dt._init_hio(hio)
            dt._on_connect()
            await waiter
            return dt, proto_obj

        if remote_addr is not None and local_addr is None:
            # UDP client
            hio = hv.hloop_create_udp_client(self.hvloop, remote_addr[0].encode('utf-8'), <int>remote_addr[1])
            if hio == NULL:
                raise RuntimeError('failed to create udp client')
            dt = DatagramTransport(self, proto_obj, remote_addr, waiter, None)
            dt._init_hio(hio)
            dt._on_connect()
            await waiter
            return dt, proto_obj

        raise NotImplementedError('simultaneous local_addr and remote_addr is not supported yet')

