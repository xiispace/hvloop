
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
