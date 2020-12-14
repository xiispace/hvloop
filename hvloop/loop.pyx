# cython: language_level=3, embedsignature=True
import asyncio
import concurrent.futures
import collections
import time
import traceback
import socket

cimport cython
from cython.operator cimport dereference as deref
from libc.stdint cimport uint32_t, uint64_t
from libc.string cimport memset
from cpython cimport PyObject
from cpython cimport (
    Py_INCREF, Py_DECREF, Py_XDECREF, Py_XINCREF,
    PyBytes_AS_STRING, Py_SIZE
)

from .includes.python cimport (
    PY_VERSION_HEX,
    PyMem_RawMalloc,
    PyUnicode_FromString
)

cdef tb_format_list = traceback.format_list
cdef aio_logger = asyncio.log.logger
cdef aio_Future = asyncio.Future
cdef aio_Task = asyncio.Task
cdef aio_ensure_future = asyncio.ensure_future
cdef aio_isfuture = asyncio.isfuture
cdef aio_Handle = asyncio.Handle
cdef aio_wrap_future = asyncio.wrap_future
cdef aio_set_running_loop = asyncio._set_running_loop
cdef aio_get_running_loop = asyncio._get_running_loop
cdef cc_ThreadPoolExecutor = concurrent.futures.ThreadPoolExecutor
cdef socket_getaddrinfo = socket.getaddrinfo
cdef socket_getnameinfo = socket.getnameinfo


cdef:
    int PY37 = PY_VERSION_HEX >= 0x03070000
    int PY36 = PY_VERSION_HEX >= 0x03060000
    uint64_t MAX_SLEEP = 3600 * 24 * 365 * 100
    uint32_t INFINITE = <uint32_t>-1


cdef void on_idle(hv.hidle_t* idle) with gil:
    # print("on_idle: event_id=%s\tpriority=%d\t" % ((<hv.hevent_t*>idle).event_id, (<hv.hevent_t*>idle).priority))
    cdef:
        Loop loop = <Loop> (<hv.hevent_t*>idle).userdata
    # print("ready num: %d" % len(loop._ready))
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

    def __cinit__(self):
        self.hvloop = hv.hloop_new(0)

        self._timers = set()
        self._ready = collections.deque()

    def __dealloc__(self):
        hv.hloop_free(&self.hvloop)

    cdef _run(self, int flags):
        Py_INCREF(self)
        aio_set_running_loop(self)

        with nogil:
            err = hv.hloop_run(self.hvloop)
        Py_DECREF(self)
        if err < 0:
            raise ValueError("loop run error")

    # starting, stopping and closing

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
        return (self._thread_id is not None)

    def close(self):
        """

        :return:
        """
        pass

    def is_closed(self):
        pass

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
        when = <uint64_t>round(delay * 1000)
        return TimerHandle(self, callback, args, when, context)

    def call_at(self, when, callback, *args, context=None):
        return self.call_later(when - self.time(), callback, *args, context=context)

    def time(self):
        hv.hloop_update_time(self.hvloop)
        return hv.hloop_now_us(self.hvloop) / 1000

    # thread interaction
    def call_soon_threadsafe(self, callback, *args, context=None):
        # todo:
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
    @cython.iterable_coroutine
    async def getaddrinfo(self, host, port, *,
                          family=0, type=0, proto=0, flags=0):
        getaddr_func = socket_getaddrinfo
        return await self.run_in_executor(
            None, getaddr_func, host, port, family, type, proto, flags
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
        """
        """

        if host is not None and port is not None:
            pass

        else:
            if sock is None:
                raise ValueError('host and port was not specified and no sock specified')
            # if sock.type != soc
        protocol = protocol_factory()
        waiter = self.create_future()

        transport = HVSocketTransport(
            self, protocol, None, waiter
        )
        try:
            host = host.encode('ascii')
        except UnicodeError:
            host = host.encode('idna')
        try:
            transport.connect(host, port)
            await waiter
        except:
            aio_logger.error("transport connect error")
            transport.close()
            raise
        return transport, protocol


    def create_server(self):
        pass

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



cdef void on_timer(hv.htimer_t* timer) with gil:
    cdef:
        TimerHandle handle = <TimerHandle> (<hv.hevent_t*>timer).userdata
    handle._run()


@cython.no_gc_clear
@cython.freelist(250)
cdef class TimerHandle:
    def __cinit__(self, Loop loop, object callback, object args,
                  uint64_t delay, object context):

        self.loop = loop
        self.callback = callback
        self.args = args
        self._cancelled = 0

        if PY37:
            pass
            # if context is None:
            #     context = Context_CopyCurrent()
            # self.context = context
        else:
            if context is not None:
                raise NotImplementedError(
                    '"context" argument requires Python 3.7')
            self.context = None

        self._debug_info = None

        # self.timer = UVTimer.new(
        #     loop, <method_t>self._run, self, delay)
        self.timer = hv.htimer_add(self.loop.hvloop, on_timer, delay, 1)
        hv.hevent_set_userdata(<hv.hevent_t*>self.timer, <void*>self)



        # self.timer.start()

        # Only add to loop._timers when `self.timer` is successfully created
        # add self ref to disable self and self.callback release
        loop._timers.add(self)

    property _source_traceback:
        def __get__(self):
            if self._debug_info is not None:
                return self._debug_info[1]

    def __dealloc__(self):
        if not self.timer == NULL:
            raise RuntimeError('active TimerHandle is deallacating')

    cdef _cancel(self):
        if self._cancelled == 1:
            return
        self._cancelled = 1
        self._clear()

    cdef inline _clear(self):
        if self.timer == NULL:
            return

        self.callback = None
        self.args = None
        try:
            self.loop._timers.remove(self)
        finally:
            hv.htimer_del(self.timer)
            self.timer = NULL  # let the UVTimer handle GC

    cdef _run(self):
        if self._cancelled == 1:
            return

        if self.callback is None:
            raise RuntimeError('cannot run TimerHandle; callback is not set')


        callback = self.callback
        args = self.args


        # Since _run is a cdef and there's no BoundMethod,
        # we guard 'self' manually.
        Py_INCREF(self)

        # if self.loop._debug:
            # started = time_monotonic()
        try:
            # if PY37:
                # assert self.context is not None
                # Context_Enter(self.context)

            if args is not None:
                callback(*args)
            else:
                callback()
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as ex:
            context = {
                'message': 'Exception in callback {}'.format(callback),
                'exception': ex,
                'handle': self,
            }

            # if self._debug_info is not None:
            #     context['source_traceback'] = self._debug_info[1]

            self.loop.call_exception_handler(context)
        else:
            pass
            # if self.loop._debug:
            #     pass
                # delta = time_monotonic() - started
                # if delta > self.loop.slow_callback_duration:
                #     aio_logger.warning(
                #         'Executing %r took %.3f seconds',
                #         self, delta)
        finally:
            context = self.context
            Py_DECREF(self)
            # if PY37:
            #     Context_Exit(context)
            self._clear()

    # Public API

    def __repr__(self):
        info = [self.__class__.__name__]

        if self._cancelled:
            info.append('cancelled')

        if self._debug_info is not None:
            callback_name = self._debug_info[0]
            source_traceback = self._debug_info[1]
        else:
            callback_name = None
            source_traceback = None

        if callback_name is not None:
            info.append(callback_name)
        elif self.callback is not None:
            info.append(format_callback_name(self.callback))

        if source_traceback is not None:
            frame = source_traceback[-1]
            info.append('created at {}:{}'.format(frame[0], frame[1]))

        return '<' + ' '.join(info) + '>'

    def cancelled(self):
        return self._cancelled

    def cancel(self):
        self._cancel()


cdef format_callback_name(func):
    if hasattr(func, '__qualname__'):
        cb_name = getattr(func, '__qualname__')
    elif hasattr(func, '__name__'):
        cb_name = getattr(func, '__name__')
    else:
        cb_name = repr(func)
    return cb_name



cdef void on_connect(hv.hio_t* io) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata
    transport._on_connect()


cdef void on_recv(hv.hio_t* io, void* buf, int readbytes) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata
    transport._on_recv(buf, readbytes)


@cython.no_gc_clear
cdef class HVSocketTransport:

    def __cinit__(self, Loop loop, object protocol, object server, object waiter):
        self.loop = loop
        self._server = server
        self._waiter = waiter
        self._extra_info = dict()

        self._eof = 0
        self._buffer = []

        self.set_protocol(protocol)
        self._conn_lost = 0
        self._closing = 0


    def __repr__(self):
        return '<{} closed=1 {:#x}>'.format(
            self.__class__.__name__,
            id(self)
        )

    def __dealloc__(self):
        pass

    def get_extra_info(self, name, default=None):
        return self._extra_info.get(name, default)

    cdef void connect(self, const char* host, int port):
        self._io = hv.hloop_create_tcp_client(self.loop.hvloop, host, port, on_connect)
        hv.hevent_set_userdata(<hv.hevent_t*>self._io, <void*>self)

        self._start_reading()

    cdef _start_reading(self):
        hv.hio_setcb_read(self._io, on_recv)
        hv.hio_read(self._io)
        # hv.hio_set_readbuf(self._io, self.loop._recv_buf, 8192)

    cdef _on_connect(self):
        # 填写 sockanme 和 peername
        #todo: support ipv6
        self._extra_info["sockname"] = convert_sockaddr_to_pyaddr(hv.hio_localaddr(self._io))
        self._extra_info["peername"] = convert_sockaddr_to_pyaddr(hv.hio_peeraddr(self._io))

        self.loop.call_soon(self._protocol.connection_made, self)
        self._waiter.set_result(True)

    cdef _on_recv(self, void *buf, int n):
        cdef bytes py_bytes
        try:
            py_bytes = (<char*>buf)[:n]
            self._protocol.data_received(py_bytes)
        except BaseException as exc:
            self._fatal_error(exc)

    cdef _write(self, object data):
        pass

    def write(self, object data):
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError('data argument must be a bytes-like object, not {}'.format(type(data).__name__))

        if not data:
            return

        cdef:
            void* buf
            size_t blen

        buf = <void*>PyBytes_AS_STRING(data)
        blen = Py_SIZE(data)
        n = hv.hio_write(self._io, buf, blen)
        if n < 0:
            exc = Exception()
            self._fatal_error()
            raise exc
        else:
            aio_logger.info("send: %s, buf: %s", n, blen)
            data = data[n:]
            if not data:
                return

        self._buffer.extend(data)
        self._maybe_pause_protocol()

    def get_protocol(self):
        return self._protocol

    def set_protocol(self, protocol):
        self._protocol = protocol

    def writelines(self, list_of_data):
        data = b''.join(list_of_data)
        self.write(data)

    def write_eof(self):
        self._eof = 1

    def can_write_eof(self):
        return True

    # flow control
    cdef inline _maybe_pause_protocol(self):
        cdef:
            size_t size = self._get_write_buffer_size()
        if size <= self._high_water:
            return

        if not self._protocol_paused:
            self._protocol_paused = 1
            try:
                self._protocol.pause_writing()
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.pause_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    cdef inline _maybe_resume_protocol(self):
        cdef:
            size_t size = self._get_write_buffer_size()
        if (self._protocol_paused and
            size <= self._low_water):
            self._protocol_paused = 0
            try:
                self._protocol.resume_writing()
            except (SystemExit, KeyboardInterrupt):
                raise
            except BaseException as exc:
                self._loop.call_exception_handler({
                    'message': 'protocol.resume_writing() failed',
                    'exception': exc,
                    'transport': self,
                    'protocol': self._protocol,
                })

    cdef size_t _get_write_buffer_size(self):
        return 0

    def get_write_buffer_size(self):
        return self._get_write_buffer_size()

    def _set_write_buffer_limits(self, high=None, low=None):
        if high is None:
            if low is None:
                high = 64 * 1024
            else:
                high = 4 * low
        if low is None:
            low = high // 4

        if not high >= low >= 0:
            raise ValueError('high ({}) must be >= low ({}) must be >= 0'.format(high, low))
        self._high_water = high
        self._low_water = low

    def set_writer_buffer_limits(self, high=None, low=None):
        self._set_write_buffer_limits(high, low)
        self._maybe_pause_protocol()

    def get_writer_buffer_limits(self):
        return (self._low_water, self._high_water)

    def pause_reading(self):
        pass

    def resume_reading(self):
        pass

    def is_closing(self):
        return self._closing

    def close(self):
        self._closing = 1

    def abort(self):
        pass

    def _fatal_error(self, exc, message='Fatal error on transport'):
        # Should be called from exception handler only.
        if isinstance(exc, OSError):
            pass
            # if self._loop.get_debug():
                # logger.debug("%r: %s", self, message, exc_info=True)
        else:
            self._loop.call_exception_handler({
                'message': message,
                'exception': exc,
                'transport': self,
                'protocol': self._protocol,
            })
        self._force_close(exc)

    def _force_close(self, exc):
        if self._conn_lost:
            return
        if self._buffer:
            self._buffer.clear()
            # self._loop._remove_writer(self._sock_fd)
        if not self._closing:
            self._closing = 1
            # self._loop._remove_reader(self._sock_fd)
        self._conn_lost += 1
        self._loop.call_soon(self._call_connection_lost, exc)



cdef convert_sockaddr_to_pyaddr(hv.sockaddr* addr):
    cdef:
        char buf[128]
        hv.sockaddr_in *addr4
        hv.sockaddr_in6 *addr6

    if addr.sa_family == hv.AF_INET:
        addr4 = <hv.sockaddr_in*>addr

        hv.sockaddr_str(<hv.sockaddr_u*>addr4, buf, sizeof(buf))
        host, port = PyUnicode_FromString(buf).rsplit(':', 1)
        return (host, int(port))
    elif addr.sa_family == hv.AF_INET6:
        addr6 = <hv.sockaddr_in6*>addr
        hv.sockaddr_str(<hv.sockaddr_u*>addr6, buf, sizeof(buf))
        host, port = PyUnicode_FromString(buf).rsplit(':', 1)
        return (host, port, hv.ntohl(addr6.sin6_flowinfo), addr6.sin6_scope_id)

    raise RuntimeError("cannot convert sockaddr into Python object")

