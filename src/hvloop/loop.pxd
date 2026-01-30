from .includes.hv cimport hloop_t, hio_t
from libc.stdint cimport uint32_t, uint64_t

cdef class Loop:
    cdef:
        hloop_t* hvloop
        bint _debug
        bint _closed
        bint _stopping
        uint64_t _thread_id
        object _ready
        object _timers
        object _exception_handler
        object _default_executor

    cdef _run(self, int flags)
    cdef uint64_t _time(self)
    cdef _wakeup(self)
    cdef _make_hio_transport(self, hio_t* io, object protocol, object waiter, object extra, object server)

