cdef class Server:
    cdef:
        Loop _loop
        list _sockets
        int _backlog
        object _protocol_factory
        object _ssl_context
        object _serving_forever_fut

        object ssl_handshake_timeout
        object ssl_shutdown_timeout
        bint _serving
        int _active_count
        hv.hio_t** _server_io_list

        list _waiters

    cdef _start_serving(self)
    cdef _on_accept(self, hv.hio_t* io)
