
cdef void on_timer(hv.htimer_t* timer) with gil:
    cdef:
        TimerHandle handle = <TimerHandle> (<hv.hevent_t*>timer).userdata
    handle._run()


@cython.no_gc_clear
@cython.freelist(250)
cdef class TimerHandle:
    def __cinit__(self, Loop loop, object callback, object args,
                  uint32_t delay, object context):

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
