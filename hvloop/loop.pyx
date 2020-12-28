# cython: language_level=3, embedsignature=True
import os
import sys
import asyncio
import concurrent.futures
import collections
import traceback
import socket
import itertools

cimport cython
from cython.operator cimport dereference as deref
from libc.stdint cimport uint32_t, uint64_t
from libc.string cimport memset
from cpython cimport PyObject
from cpython cimport (
    Py_INCREF, Py_DECREF, Py_XDECREF, Py_XINCREF,
    PyBytes_AS_STRING, Py_SIZE, PyThread_get_thread_ident
)

from .includes.python cimport (
    PY_VERSION_HEX,
    PyMem_RawMalloc,
    PyMem_RawFree,
    PyUnicode_FromString
)

cdef os_environ = os.environ
cdef os_name = os.name
cdef sys_platform = sys.platform
cdef sys_ignore_environment = sys.flags.ignore_environment
cdef tb_format_list = traceback.format_list
cdef aio_logger = asyncio.log.logger
cdef aio_Future = asyncio.Future
cdef aio_Task = asyncio.Task
cdef aio_ensure_future = asyncio.ensure_future
cdef aio_isfuture = asyncio.isfuture
cdef aio_Handle = asyncio.Handle
cdef aio_wrap_future = asyncio.wrap_future
cdef aio_gather = asyncio.gather
cdef aio_set_running_loop = asyncio._set_running_loop
cdef aio_get_running_loop = asyncio._get_running_loop
cdef cc_ThreadPoolExecutor = concurrent.futures.ThreadPoolExecutor
cdef future_set_result_unless_cancelled = asyncio.futures._set_result_unless_cancelled

cdef int has_IPV6_V6ONLY = hasattr(socket, 'IPV6_V6ONLY')
cdef int IPV6_V6ONLY = getattr(socket, 'IPV6_V6ONLY', -1)
cdef int has_SO_REUSEPORT = hasattr(socket, 'SO_REUSEPORT')
cdef int SO_REUSEPORT = getattr(socket, 'SO_REUSEPORT', 0)
cdef socket_getaddrinfo = socket.getaddrinfo
cdef socket_getnameinfo = socket.getnameinfo
cdef socket_socket = socket.socket
cdef socket_error = socket_error

cdef col_deque = collections.deque
cdef col_Iterable = collections.abc.Iterable

cdef chain_from_iterable = itertools.chain.from_iterable


cdef:
    int PY37 = PY_VERSION_HEX >= 0x03070000
    int PY36 = PY_VERSION_HEX >= 0x03060000
    uint64_t MAX_SLEEP = 3600 * 24 * 365 * 100
    uint32_t INFINITE = <uint32_t>-1


cdef void on_idle(hv.hidle_t* idle) with gil:
    cdef:
        Loop loop = <Loop> (<hv.hevent_t*>idle).userdata
    ntodo = len(loop._ready)
    for i in range(ntodo):
        handle = loop._ready.popleft()
        if handle._cancelled:
            continue
        handle._run()
    handle = None
    # time.sleep(2)

    if loop._stopping:
        hv.hloop_stop(loop.hvloop)


@cython.no_gc_clear
cdef class Loop:
    """
    https://www.python.org/dev/peps/pep-3156/#event-loop-methods-overview
    """

    def __cinit__(self):
        self.hvloop = hv.hloop_new(0)

        self._debug = 0
        self._thread_id = 0
        self._closed = 0
        self._stopping = 0

        self._timers = set()

        self._task_factory = None
        self._exception_handler = None
        self._default_executor = None
        self._ready = col_deque()

    def __init__(self):
        self.set_debug((not sys_ignore_environment
                        and bool(os_environ.get('PYTHONASYNCIODEBUG'))))

    def __dealloc__(self):
        if self._closed == 0:
            aio_logger.warning("unclosed event loop")
            # not self.is_running()
            if self._thread_id != 0:
                self.close()

        hv.hloop_free(&self.hvloop)

    def __repr__(self):
        return '<{} running={} closed={} debug={}>'.format(
            self.__class__.__name__, self.is_running(), self.is_closed(), self.get_debug()
        )

    # starting, stopping and closing
    cdef _run(self, int flags):
        Py_INCREF(self)
        aio_set_running_loop(self)
        self._thread_id = PyThread_get_thread_ident()

        with nogil:
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
        new_task = not aio_isfuture(future)

        future = aio_ensure_future(future, loop=self)
        if new_task:
            # An exception is raised if the future didn't complete, so there
            # is no need to log the "destroy pending task" message
            future._log_destroy_pending = False

        def _run_until_complete_cb(fut):
            if not fut.cancelled():
                exc = fut.exception()
                if isinstance(exc, (SystemExit, KeyboardInterrupt)):
                    # Issue #22429: run_forever() already finished, no need to
                    # stop it.
                    return
            self.stop()

        stop_cb = lambda :self.stop()
        future.add_done_callback(_run_until_complete_cb)
        try:
            self.run_forever()
        except:
            if new_task and future.done() and not future.cancelled():
                # The coroutine raised a BaseException. Consume the exception
                # to not log a warning, the caller doesn't have access to the
                # local task.
                future.exception()
            raise
        finally:
            future.remove_done_callback(_run_until_complete_cb)
        if not future.done():
            raise RuntimeError('Event loop stopped before Future completed.')

        return future.result()


    def stop(self):
        """Stop running the event loop.

        Every callback already scheduled will still run.  This simply informs
        run_forever to stop looping after a complete iteration.
        """
        self._stopping = 1

    def is_running(self):
        return (self._thread_id != 0)

    def close(self):
        """Close the event loop.

        This clears the queues and shuts down the executor,
        but does not wait for the executor to finish.

        The event loop must not be running.
        """
        if self.is_running():
            raise RuntimeError("Cannot close a running event loop")
        if self._closed:
            return
        if self._debug:
            aio_logger.debug("Close %r", self)
        self._closed = 1
        self._ready.clear()
        # self._scheduled.clear()
        executor = self._default_executor
        if executor is not None:
            self._default_executor = None
            executor.shutdown(wait=False)

    def is_closed(self):
        return self._closed

    # basic and timed callbacks
    def call_soon(self, callback, *args, context=None):
        handle = self._call_soon(callback, args, context)
        return handle

    cdef inline _call_soon(self, object callback, object args, object context):
        handle = aio_Handle(callback, args, self, context)
        self._ready.append(handle)
        return handle


    def call_later(self, delay, callback, *args, context=None):
        if delay < 0:
            delay = 0
        if not args:
            args = None
        # s -> ms
        when = <uint32_t>round(delay * 1000)
        return TimerHandle(self, callback, args, when, context)

    def call_at(self, when, callback, *args, context=None):
        return self.call_later(when - self.time(), callback, *args, context=context)

    cdef uint64_t _time(self):
        hv.hloop_update_time(self.hvloop)
        return hv.hloop_now_us(self.hvloop)

    def time(self):
        return self._time() / 1000

    # thread interaction
    def call_soon_threadsafe(self, callback, *args, context=None):
        # todo: check
        handle = self._call_soon(callback, args, context)
        return handle

    def run_in_executor(self, executor, func, *args):
        if executor is None:
            executor = self._default_executor
            if executor is None:
                executor = cc_ThreadPoolExecutor()
                self.set_default_executor = executor
        return aio_wrap_future(
            executor.submit(func, *args), loop=self
        )

    def set_default_executor(self, executor):
        self._default_executor = executor

    # internet name lookups
    cdef _make_socket_transport(self, int sock, protocol, waiter, extra, server):
        cdef hv.hio_t* hio = hv.hio_get(self.hvloop, sock)
        return self._make_hio_transport(hio, protocol, waiter, extra, server)

    cdef _make_hio_transport(self, hv.hio_t* hio, protocol, waiter, extra, server):
        tr = HVSocketTransport(self, protocol, waiter, extra, server)
        tr._init_hio(hio)
        tr._on_connect()
        return tr

    @cython.iterable_coroutine
    async def getaddrinfo(self, host, port, *,
                          family=0, type=0, proto=0, flags=0):
        return await self.run_in_executor(
            None, socket_getaddrinfo, host, port, family, type, proto, flags
        )

    @cython.iterable_coroutine
    async def getnameinfo(self, sockaddr, flags=0):
        return await self.run_in_executor(
            None, socket_getnameinfo, sockaddr, flags
        )

    #internet connections
    @cython.iterable_coroutine
    async def create_connection(
            self, protocol_factory, host=None, port=None,
            *, ssl=None, family=0,
            proto=0, flags=0, sock=None,
            local_addr=None, server_hostname=None,
            ssl_handshake_timeout=None,
            happy_eyeballs_delay=None, interleave=None):
        protocol = protocol_factory()
        waiter = self.create_future()
        if ssl:
            raise ValueError("not support now")

        if host is not None and port is not None:
            try:
                host = host.encode('ascii')
            except UnicodeError:
                host = host.encode('idna')
            try:
                transport = HVSocketTransport.connect(
                    self, host, port, protocol, waiter, None, None
                )
                # transport.connect(host, port)
                await waiter
            except:
                aio_logger.error("transport connect error")
                # transport.close()
                raise
            pass
        else:
            if sock is None:
                raise ValueError('host and port was not specified and no sock specified')
            transport = self._make_socket_transport(sock.fileno(), protocol, waiter, None, None)
            await waiter

        return transport, protocol


    async def create_server(
            self, protocol_factory, host=None, port=None,
            *,
            family=socket.AF_UNSPEC,
            flags=socket.AI_PASSIVE,
            sock=None,
            backlog=100,
            ssl=None,
            reuse_address=None,
            reuse_port=None,
            ssl_handshake_timeout=None,
            start_serving=True):
        """Create a TCP server.

        The host parameter can be a string, in that case the TCP server is
        bound to host and port.

        The host parameter can also be a sequence of strings and in that case
        the TCP server is bound to all hosts of the sequence. If a host
        appears multiple times (possibly indirectly e.g. when hostnames
        resolve to the same IP address), the server is only bound once to that
        host.

        Return a Server object which can be used to stop the service.

        This method is a coroutine.
        """
        if isinstance(ssl, bool):
            raise TypeError('ssl argument must be an SSLContext or None')

        if ssl_handshake_timeout is not None and ssl is None:
            raise ValueError(
                'ssl_handshake_timeout is only meaningful with ssl')

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the same time')

            if reuse_address is None:
                reuse_address = os_name == 'posix' and sys_platform != 'cygwin'

            if reuse_port and not has_SO_REUSEPORT:
                raise ValueError('reuse_port not supported by socket module')

            sockets = []
            if host == '':
                hosts = [None]
            elif (isinstance(host, str) or
                  not isinstance(host, col_Iterable)):
                hosts = [host]
            else:
                hosts = host

            fs = [self.getaddrinfo(host, port, family=family, type=hv.SOCK_STREAM, flags=flags)
                  for host in hosts]
            infos = await aio_gather(*fs, loop=self)
            infos = set(chain_from_iterable(infos))

            completed = False
            try:
                for res in infos:
                    af, socktype, proto, canonname, sa = res
                    try:
                        sock = socket_socket(af, socktype, proto)
                    except socket.error:
                        # Assume it's a bad family/type/protocol combination.
                        if self._debug:
                            aio_logger.warning('create_server() failed to create '
                                           'socket.socket(%r, %r, %r)',
                                           af, socktype, proto, exc_info=True)
                        continue
                    sockets.append(sock)
                    if reuse_address:
                        sock.setsockopt(
                            hv.SOL_SOCKET, hv.SO_REUSEADDR, True)
                    if reuse_port:
                        sock.setsockopt(hv.SOL_SOCKET, SO_REUSEPORT, 1)
                    # Disable IPv4/IPv6 dual stack support (enabled by
                    # default on Linux) which makes a single socket
                    # listen on both address families.
                    if af == hv.AF_INET6 and has_IPV6_V6ONLY:

                        sock.setsockopt(hv.IPPROTO_IPV6,
                                        IPV6_V6ONLY,
                                        True)
                    try:
                        sock.bind(sa)
                    except OSError as err:
                        raise OSError(err.errno, 'error while attempting '
                                      'to bind on address %r: %s'
                                      % (sa, err.strerror.lower())) from None
                completed = True
            finally:
                if not completed:
                    for sock in sockets:
                        sock.close()
        else:
            if sock is None:
                raise ValueError('Neither host/port nor sock were specified')
            if sock.type != socket.SOCK_STREAM:
                raise ValueError(f'A Stream Socket was expected, got {sock!r}')
            sockets = [sock]

        for sock in sockets:
            sock.setblocking(False)

        server = Server(self, sockets, protocol_factory,
                        ssl, backlog, ssl_handshake_timeout)

        if start_serving:
            server._start_serving()
            # Skip one loop iteration so that all 'loop.add_reader'
            # go through.
            # await tasks.sleep(0, loop=self)

        if self._debug:
            aio_logger.info("%r is serving", server)
        return server

    def create_datagram_endpoint(self):
        pass

    # tasks and futures support
    def create_future(self):
        return aio_Future(loop=self)

    def create_task(self, coro, *, name=None):
        if self._task_factory is None:
            task = aio_Task(coro, loop=self, name=name)
        else:
            task = self._task_factory(self, coro)
        return task

    def set_task_factory(self, factory):
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

    # error handling
    def get_exception_handler(self):
        return self._exception_handler

    def set_exception_handler(self, handler):
        if handler is not None and not callable(handler):
            return TypeError("A callable object or None is expected, ",
                             "got {!r}".format(handler))
        return self._exception_handler

    def default_exception_handler(self, context):
        """Default exception handler.

        This is called when an exception occurs and no exception
        handler is set, and can be called by a custom exception
        handler that wants to defer to the default behavior.

        The context parameter has the same meaning as in
        `call_exception_handler()`.
        """
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        log_lines = [message]
        for key in sorted(context):
            if key in {'message', 'exception'}:
                continue
            value = context[key]
            if key == 'source_traceback':
                tb = ''.join(tb_format_list(value))
                value = 'Object created at (most recent call last):\n'
                value += tb.rstrip()
            else:
                try:
                    value = repr(value)
                except (KeyboardInterrupt, SystemExit):
                    raise
                except BaseException as ex:
                    value = ('Exception in __repr__ {!r}; '
                             'value type: {!r}'.format(ex, type(value)))
            log_lines.append('{}: {}'.format(key, value))

        aio_logger.error('\n'.join(log_lines), exc_info=exc_info)

    def call_exception_handler(self, context):
        if self._exception_handler is None:
            try:
                self.default_exception_handler(context)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException:
                # Second protection layer for unexpected errors
                # in the default implementation, as well as for subclassed
                # event loops with overloaded "default_exception_handler".
                aio_logger.error('Exception in default exception handler', exc_info=True)
        else:
            try:
                self._exception_handler(self, context)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as exc:
                # Exception in the user set custom exception handler.
                try:
                    # Let's try default handler.
                    self.default_exception_handler({
                        'message': 'Unhandled error in exception handler',
                        'exception': exc,
                        'context': context,
                    })
                except (KeyboardInterrupt, SystemExit):
                    raise
                except BaseException:
                    # Guard 'default_exception_handler' in case it is
                    # overloaded.
                    aio_logger.error('Exception in default exception handler '
                                     'while handling an unexpected error '
                                     'in custom exception handler',
                                     exc_info=True)


    # debug mode
    def get_debug(self):
        return self._debug

    def set_debug(self, enabled):
        self._debug = bool(enabled)

        if self.is_running():
            pass


include "server.pyx"
include "transport.pyx"
include "handle.pyx"

