
from .includes.hv cimport htimer_t
from .loop cimport Loop

cdef class TimerHandle:
    cdef:
        object callback
        tuple args
        bint _cancelled
        htimer_t* timer
        Loop loop
        object context
        tuple _debug_info
        object __weakref__

    cdef _run(self)
    cdef _cancel(self)
    cdef inline _clear(self)
