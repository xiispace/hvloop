from .includes cimport hv
from libc.stdint cimport uint32_t, uint64_t

# cdef extern from *:
#     ctypedef int vint "volatile int"

cdef class Loop:
    cdef:
        hv.hloop_t* hvloop

        bint _debug
        bint _closed
        bint _stopping

        int _conn_lost

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
    cdef _make_socket_transport(self, object sock, object protocol, object waiter, object extra, object server)
    cdef _make_datagram_transport(self, object sock, object protocol, object address, object waiter, object extra)
    cdef _make_hio_transport(self, hv.hio_t* hio, protocol, waiter, extra, server)
    cdef uint64_t _time(self)
    cdef _wake_up(self)



include "server.pxd"
include "transport.pxd"
include "handle.pxd"

