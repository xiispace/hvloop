
@cython.no_gc_clear
cdef class Server:
    """
    events.AbstractServer
    """
    def __cinit__(self, Loop loop, list sockets, object protocol_factory,
                  object ssl, int backlog, object ssl_handshake_timeout):

        self._loop = loop
        self._sockets = sockets
        self._protocol_factory = protocol_factory
        self._backlog = backlog
        self._ssl_context = ssl
        self._serving_forever_fut = None
        self._serving = 0
        self.ssl_handshake_timeout = None
        self.ssl_shutdown_timeout = None
        self._active_count = 0
        self._waiters = []

        self._server_io_list = <hv.hio_t**>PyMem_RawMalloc(
            len(self._sockets) * sizeof(hv.hio_t*)
        )

    def __dealloc__(self):
        PyMem_RawFree(self._server_io_list)
        self._server_io_list = NULL

    def __repr__(self):
        return "<{} sockets={}>".format(self.__class__.__name__, self._sockets)

    def _wakeup(self):
        waiters = self._waiters
        self._waiters = None
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(waiter)

    def close(self):
        cdef int idx = 0
        while idx < len(self._sockets):
            hv.hio_close(self._server_io_list[idx])
            idx += 1

        self._serving = 0

        if (self._serving_forever_fut is not None and not
        self._serving_forever_fut.done()):
            self._serving_forever_fut.cancel()
            self._serving_forever_fut = None

        if self._active_count == 0:
            self._wakeup()

    @cython.iterable_coroutine
    async def wait_closed(self):
        if self._sockets is None or self._waiters is None:
            return
        waiter = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter

    def get_loop(self):
        return self._loop

    def is_serving(self):
        return self._serving

    cdef _on_accept(self, hv.hio_t* io):
        protocol = self._protocol_factory()
        self._loop._make_hio_transport(io, protocol, None, None, self)

    cdef _start_serving(self):
        if self._serving == 1:
            return
        self._serving = 1
        cdef:
            hv.hio_t* io
            int idx = 0

        for sock in self._sockets:
            sock.listen(self._backlog)
            io = hv.haccept(self._loop.hvloop, <int>sock.fileno(), on_accept)
            hv.hevent_set_userdata(<hv.hevent_t*> io, <void*> self)

            self._server_io_list[idx] = io
            idx += 1

    @cython.iterable_coroutine
    async def start_serving(self):
        self._start_serving()

    async def serve_forever(self):
        if self._serving_forever_fut is not None:
            raise RuntimeError(
                f'server {self!r} is already being awaited on serve_forever()')
        if self._sockets is None:
            raise RuntimeError(f'server {self!r} is closed')


        self._start_serving()
        self._serving_forever_fut = self._loop.create_future()

        try:
            await self._serving_forever_fut
        except asyncio.CancelledError:
            try:
                self.close()
                await self.wait_closed()
            finally:
                raise
        finally:
            self._serving_forever_fut = None

    def _attach(self):
        """will call when init a transport"""
        self._active_count += 1

    def _detach(self):
        """call when transport closed"""
        self._active_count -= 1
        if self._active_count == 0 and self._sockets is None:
            self._wakeup()

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        self.close()
        await self.wait_closed()

cdef void on_accept(hv.hio_t* io) with gil:
    cdef:
        Server server = <Server> (<hv.hevent_t*> io).userdata

    server._on_accept(io)
