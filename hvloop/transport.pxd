
cdef class HVSocketTransport:
    cdef:
        object _protocol
        object _waiter
        object _server

        dict _extra_info
        Loop _loop
        hv.hio_t* _hio
        size_t _buffer_size
        size_t _high_water
        size_t _low_water

        # _SelectorSocketTransport
        bint _eof

        # _SelectorTransport
        size_t _conn_lost
        bint _closing
        bint _protocol_connected
        bint _protocol_paused

    # cdef void connect(self, const char* host, int port)
    # cdef _accept(self, hv.hio_t* io, object server)

    cdef _init_hio(self, hv.hio_t* hio)

    @staticmethod
    cdef HVSocketTransport connect(Loop loop, const char* host, int port, object protocol, object waiter,
                                   object extra, object server)
    cdef _set_server(self, Server server)
    # cdef _call_connection_made(self)
    cdef _schedule_call_connection_lost(self, exc)
    # cdef _call_connection_lost(self, exc)
    cdef _on_connect(self)
    cdef _on_recv(self, void* buf, int n)

    cdef size_t _get_write_buffer_size(self)

    # cdef _write(self, object data)
    cdef inline _maybe_pause_protocol(self)
    cdef inline _maybe_resume_protocol(self)

    cdef _start_reading(self)
    cdef _stop_reading(self)
