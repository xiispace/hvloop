
cdef void on_connect(hv.hio_t* io) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata
    transport._on_connect()


cdef void on_recv(hv.hio_t* io, void* buf, int readbytes) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata
    transport._on_recv(buf, readbytes)



def cfun_wrapper(cfun, *args):
    cfun(*args)


@cython.no_gc_clear
cdef class HVSocketTransport:
    """
    client socket
    or server accept socket
    """

    def __cinit__(self, Loop loop, protocol, waiter=None,
                  extra=None, server=None):
        self._loop = loop
        self._protocol = None
        self._server = server
        self._waiter = waiter
        self._extra_info = dict()
        self._hio = NULL
        self._eof = 0
        # no need buffer, use hio_write intern buf
        self._buffer_size = 0

        # flow control
        self._high_water = 64 * 1024
        self._low_water = 64 // 4

        self.set_protocol(protocol)
        if server is not None:
            self._set_server(server)
        self._conn_lost = 0
        self._closing = 0

        self._protocol_connected = 0
        self._protocol_paused = 0


    def __repr__(self):
        return '<{} closed=1 {:#x}>'.format(
            self.__class__.__name__,
            id(self)
        )

    def __dealloc__(self):
        pass

    cdef _init_hio(self, hv.hio_t* hio):
        self._hio = hio
        hv.hevent_set_userdata(<hv.hevent_t*>self._hio, <void*>self)

    def get_extra_info(self, name, default=None):
        return self._extra_info.get(name, default)

    cdef _set_server(self, Server server):
        self._server = server
        self._server._attach()

    @staticmethod
    cdef HVSocketTransport connect(Loop loop, const char* host, int port, object protocol, object waiter,
                  object extra, object server):
        cdef:
            HVSocketTransport tr
            hv.hio_t* hio
        # todo: libhv 怎么处理连接超时的问题， 其内部 调用 hio_connect 失败的问题
        # waiter set exception ?
        hio = hv.hloop_create_tcp_client(loop.hvloop, host, port, on_connect)
        if hio == NULL:
            raise ValueError("connect error")
        tr = HVSocketTransport(loop, protocol, waiter, extra, server)
        tr._init_hio(hio)
        return tr


    cdef _start_reading(self):
        hv.hio_setcb_read(self._hio, on_recv)
        hv.hio_read(self._hio)
        # hv.hio_set_readbuf(self._io, self.loop._recv_buf, 8192)

    cdef _stop_reading(self):
        hv.hio_del(self._hio, hv.HV_READ)


    cdef _on_connect(self):
        # 填写 sockanme 和 peername
        self._extra_info["sockname"] = convert_sockaddr_to_pyaddr(hv.hio_localaddr(self._hio))
        self._extra_info["peername"] = convert_sockaddr_to_pyaddr(hv.hio_peeraddr(self._hio))
        self._loop.call_soon(self._call_connection_made)


    def _call_connection_made(self):
        self._protocol_connected = 1
        self._protocol.connection_made(self)
        self._start_reading()

        if self._waiter is not None and  not self._waiter.cancelled():
            self._waiter.set_result(None)


    def _call_connection_lost(self, exc):

        try:
            if self._protocol_connected:
                self._protocol.connection_lost(exc)
        finally:
            self._protocol = None
            # close socket
            server = self._server
            if server is not None:
                server._detach()
                self._server = None


    cdef _on_recv(self, void *buf, int n):
        cdef bytes py_bytes
        try:
            py_bytes = (<char*>buf)[:n]
            self._protocol.data_received(py_bytes)
        except BaseException as exc:
            self._fatal_error(exc)


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
        self._buffer_size += blen
        n = hv.hio_write(self._hio, buf, blen)
        if n < 0:
            exc = Exception()
            self._fatal_error()
            raise exc
        else:
            self._buffer_size -= n
            aio_logger.info("send: %s, buf: %s", n, blen)
            if self._buffer_size > 0:
                # todo: add io_close_cb, check io send error?
                hv.hio_setcb_write(self._hio, on_data_write)
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
        return self._buffer_size

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
        if self._closing == 1:
            return
        self._closing = 1

        # stop reader event
        self._stop_reading()

        # wait all data send out, timeout 60s
        hv.hio_setcb_close(self._hio, on_hio_close)
        hv.hio_close(self._hio)


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

    cdef _schedule_call_connection_lost(self, exc):
        self._loop.call_soon(self._call_connection_lost, exc)

    def _force_close(self, exc):
        if self._conn_lost:
            return
        # clear hio close cb
        hv.hio_free(self._hio)
            # self._loop._remove_writer(self._sock_fd)
        if not self._closing:
            self._closing = 1
            self._stop_reading()
        self._conn_lost += 1
        self._schedule_call_connection_lost(exc)


cdef void on_hio_close(hv.hio_t* io) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata
    transport._schedule_call_connection_lost(None)


cdef void on_data_write(hv.hio_t* io, const void* buf, int writebytes) with gil:
    cdef:
        HVSocketTransport transport = <HVSocketTransport> (<hv.hevent_t*>io).userdata

    transport._buffer_size -= writebytes
    transport._maybe_resume_protocol()  # May append to buffer.
    if transport._buffer_size <= 0:
        if transport._closing:
            transport._call_connection_lost(None)
        elif transport._eof:
            hv.hio_close(io)

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
