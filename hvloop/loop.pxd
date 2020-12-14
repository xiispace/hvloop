from .includes cimport hv
from libc.stdint cimport uint32_t, uint64_t

cdef extern from *:
    ctypedef int vint "volatile int"

cdef class Loop:
    cdef:
        hv.hloop_t* hvloop

        readonly bint _closed
        bint _stopping
        bint _debug

        bint _conn_lost

        uint64_t _thread_id

        object _task_factory
        object _exception_handler
        object _default_executor
        object _ready  # collections.deque

        set _timers
        bint _eof

        char _recv_buffer[8192]

    cdef _run(self, int flags)
    cdef inline _call_soon(self, object callback, object args, object context)


cdef class TimerHandle:
    cdef:
        object callback
        tuple args
        bint _cancelled
        hv.htimer_t* timer
        Loop loop
        object context
        tuple _debug_info
        object __weakref__

    cdef _run(self)
    cdef _cancel(self)
    cdef inline _clear(self)


cdef class HVSocketTransport:
    cdef:
        object _protocol
        object _waiter
        object _server

        dict _extra_info
        Loop loop
        hv.hio_t* _io

        # _SelectorSocketTransport
        bint _eof

        # _SelectorTransport
        list _buffer
        size_t _conn_lost
        bint _closing

    cdef void connect(self, const char* host, int port)
    cdef _on_connect(self)
    cdef _on_recv(self, void* buf, int n)

    cdef size_t _get_write_buffer_size(self)

    cdef _write(self, object data)
    cdef inline _maybe_pause_protocol(self)
    cdef inline _maybe_resume_protocol(self)

    cdef _start_reading(self)



