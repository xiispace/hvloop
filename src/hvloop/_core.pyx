# cython: language_level=3, embedsignature=True, binding=True
#
# hvloop M1 core: a self-driven asyncio-compatible event loop on top of
# libhv's hloop_process_events. See docs/plans/2026-06-13-hvloop-tech-design.md
# (sections 4 and 5, milestone M1).
#
# Design highlights (see plan section 4):
#   * We do NOT use hloop_run. run_forever() drives the loop itself: each turn
#     it runs a snapshot of the _ready deque, then calls hloop_process_events
#     with timeout 0 (ready non-empty) or a large cap (idle). hloop_process_events
#     internally clamps the poll to the nearest htimer, so timers need no manual
#     timeout math.
#   * Before entering the loop we force-create the wakeup eventfd via
#     hloop_wakeup(); otherwise libhv would sleep in an un-wakeable hv_msleep
#     when nios == 0, and call_soon_threadsafe could not interrupt it.
#   * hloop_new(0): explicitly pass 0 so HLOOP_FLAG_AUTO_FREE is NOT set
#     (the C default would double-free against our hloop_free in close()).
#   * All libhv C callbacks are ``noexcept nogil`` and re-acquire the GIL with
#     ``with gil``; their bodies are wrapped in try/except so no Python
#     exception ever propagates back into C.

import asyncio
import collections
import collections.abc
import concurrent.futures
import errno as errno_module
import os
import signal as signal_module
import socket as socket_module
import sys
import threading
import traceback

cimport cython
from libc.math cimport ceil as libc_ceil
from libc.stdint cimport uint32_t, uint64_t
from libc.string cimport memset, memcpy
from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF, Py_DECREF
from cpython.buffer cimport (PyObject_GetBuffer, PyBuffer_Release,
                             PyBUF_WRITABLE)
from cpython.bytes cimport (PyBytes_FromStringAndSize, PyBytes_AS_STRING,
                            PyBytes_GET_SIZE)

from .includes cimport hv
from .includes.python cimport PY_VERSION_HEX

# Forward declarations: Loop's create_connection/create_server reference these
# extension types, which are defined further down in this file (single
# compilation unit, plan section 3.1).
cdef class TCPTransport
cdef class Server
cdef class _TCPListener
cdef class _FDWatcher


# ---------------------------------------------------------------------------
# Module-level aliases (avoid repeated attribute lookups on hot paths).
# ---------------------------------------------------------------------------
cdef object aio_Future = asyncio.Future
cdef object aio_Task = asyncio.Task
cdef object aio_ensure_future = asyncio.ensure_future
cdef object aio_isfuture = asyncio.isfuture
cdef object aio_iscoroutine = asyncio.iscoroutine
cdef object aio_set_running_loop = asyncio._set_running_loop
cdef object col_deque = collections.deque

# A "very large" poll cap (ms). hloop_process_events clamps this to the next
# htimer anyway, so when there are timers we still wake on time; when there are
# none we block here until a wakeup eventfd write arrives. ~1 day.
cdef int _MAX_BLOCK_MS = 86400000

# Python version gate for create_task(context=...) (3.11+).
cdef int _PY311 = PY_VERSION_HEX >= 0x030b0000

# ----- TCP transport constants (plan section 6) ----------------------------
# Default write flow-control watermarks, matching asyncio's
# FlowControlMixin._set_write_buffer_limits defaults.
cdef size_t _FLOW_CONTROL_HIGH_WATER = 64 * 1024
# Mirrors asyncio.constants.LOG_THRESHOLD_FOR_CONNLOST_WRITES.
cdef int _LOG_THRESHOLD_FOR_CONNLOST_WRITES = 5
# asyncio has no implicit connect timeout (the OS decides); suppress libhv's
# 10s HIO_DEFAULT_CONNECT_TIMEOUT with a ~24-day cap instead.
cdef int _HV_CONNECT_TIMEOUT_MS = 0x7fffffff
cdef int _ECONNABORTED = errno_module.ECONNABORTED
cdef int _AF_INET = socket_module.AF_INET
cdef int _AF_INET6 = socket_module.AF_INET6

# M2b: signal handling is Unix-only (plan section 9). Runtime check rather
# than conditional compilation so the code paths stay compiled everywhere.
cdef bint _IS_WINDOWS = sys.platform == 'win32'


# ===========================================================================
# Handles
# ===========================================================================
@cython.no_gc_clear
cdef class Handle:
    """A callback scheduled via call_soon / call_soon_threadsafe.

    Mirrors asyncio.Handle's public surface closely enough for asyncio's
    internals (e.g. Task step scheduling) to use it.
    """
    cdef:
        object _callback
        tuple _args
        Loop _loop
        object _context
        bint _cancelled
        bint _repeat           # persistent handle: _run keeps callback/args
        object __weakref__

    def __cinit__(self, object callback, tuple args, Loop loop, object context):
        self._callback = callback
        self._args = args
        self._loop = loop
        self._cancelled = False
        self._repeat = False
        if context is None:
            context = copy_context()
        self._context = context

    def cancel(self):
        if not self._cancelled:
            self._cancelled = True
            self._callback = None
            self._args = None

    def cancelled(self):
        return self._cancelled

    def __repr__(self):
        info = ['Handle']
        if self._cancelled:
            info.append('cancelled')
        if self._callback is not None:
            info.append(_format_callback(self._callback, self._args))
        return '<' + ' '.join(info) + '>'

    cdef _run(self):
        if self._cancelled:
            return
        cdef object cb = self._callback
        cdef tuple args = self._args
        if cb is None:
            return
        if not self._repeat:
            # Drop references early (asyncio does the same) so the callback
            # can be garbage collected promptly after running. Repeat handles
            # (add_reader/add_writer/add_signal_handler slots, M2b) keep
            # theirs: the same Handle runs once per readiness event / signal
            # delivery until cancelled.
            self._callback = None
            self._args = None
        try:
            if args is not None:
                self._context.run(cb, *args)
            else:
                self._context.run(cb)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            cb_repr = _format_callback(cb, args)
            self._loop.call_exception_handler({
                'message': 'Exception in callback {}'.format(cb_repr),
                'exception': exc,
                'handle': self,
            })


cdef void _on_timer(hv.htimer_t* timer) noexcept nogil:
    # libhv invokes this from hloop_process_events with the GIL released.
    with gil:
        _timer_dispatch(timer)


cdef inline void _timer_dispatch(hv.htimer_t* timer):
    cdef TimerHandle handle
    cdef Loop loop
    cdef void* udata = (<hv.hevent_t*>timer).userdata
    if udata == NULL:
        return
    handle = <TimerHandle>udata
    loop = handle._loop
    # repeat=1 timers are auto-destroyed by libhv AFTER this callback returns
    # (hloop_process_pendings frees events flagged destroy). So from our side
    # the htimer_t* is no longer valid once we return: mark it gone now.
    handle._timer = NULL
    # Drop from the loop's live-timer set: this path is mutually exclusive with
    # cancel() (which removes there) and close() (which never runs while we are
    # mid-poll), so the registration DECREF below happens exactly once.
    loop._timer_handles.discard(handle)
    try:
        try:
            handle._run()
        except BaseException as exc:
            # uvloop-style pending-exception pump: a KeyboardInterrupt /
            # SystemExit raised by the callback would otherwise be swallowed by
            # the ``noexcept`` _on_timer frame ("Exception ignored ..."). Stash
            # it on the loop and stop the poll; run_forever re-raises it after
            # hloop_process_events returns, so it propagates out of
            # run_forever()/run_until_complete() per the asyncio contract.
            # (Plain Exceptions are already routed to call_exception_handler by
            # handle._run(); only KI/SE re-raise out of _run.)
            loop._pending_exc = exc
            if loop.hvloop is not NULL:
                hv.hloop_stop(loop.hvloop)
    finally:
        # Release the registration reference taken in __cinit__.
        Py_DECREF(handle)


@cython.no_gc_clear
@cython.freelist(64)
cdef class TimerHandle:
    """A callback scheduled via call_later / call_at, backed by an htimer_t."""
    cdef:
        object _callback
        tuple _args
        Loop _loop
        object _context
        bint _cancelled
        hv.htimer_t* _timer
        double _when
        object __weakref__

    def __cinit__(self, Loop loop, object callback, tuple args,
                  uint32_t delay_ms, double when, object context):
        self._loop = loop
        self._callback = callback
        self._args = args
        self._cancelled = False
        self._when = when
        self._timer = NULL
        if context is None:
            context = copy_context()
        self._context = context

        if delay_ms == 0:
            # libhv's htimer_add rejects a 0ms timeout. Per the plan, a
            # non-positive delay schedules on the next loop turn via the ready
            # queue while still returning a cancellable TimerHandle.
            loop._ready.append(self)
            return

        self._timer = hv.htimer_add(loop.hvloop, _on_timer, delay_ms, 1)
        if self._timer is NULL:
            raise RuntimeError('htimer_add failed')
        hv.hevent_set_userdata(<void*>self._timer, <void*>self)
        # Keep this handle alive while the timer is registered with libhv, and
        # track it on the loop so close() can tear down un-fired timers (which
        # libhv frees in hloop_free without invoking our callback) — otherwise
        # the registration reference below would leak and a post-close cancel()
        # would call htimer_del on a freed htimer_t* (use-after-free).
        Py_INCREF(self)
        loop._timer_handles.add(self)

    def __dealloc__(self):
        # If we still own a live timer here something leaked a reference; the
        # registration INCREF should have prevented dealloc while _timer != NULL.
        pass

    def cancel(self):
        if self._cancelled:
            return
        self._cancelled = True
        self._callback = None
        self._args = None
        cdef hv.htimer_t* t = self._timer
        if t is not NULL:
            self._timer = NULL
            hv.htimer_del(t)
            # Drop from the loop's live-timer set and release the registration
            # reference (mirrors _timer_dispatch). close() may have already
            # torn this timer down (self._timer set to NULL there), in which
            # case t is NULL and we do nothing — no double DECREF.
            self._loop._timer_handles.discard(self)
            Py_DECREF(self)

    def cancelled(self):
        return self._cancelled

    def when(self):
        return self._when

    def __repr__(self):
        info = ['TimerHandle']
        if self._cancelled:
            info.append('cancelled')
        if self._callback is not None:
            info.append(_format_callback(self._callback, self._args))
        info.append('when={!r}'.format(self._when))
        return '<' + ' '.join(info) + '>'

    cdef _run(self):
        if self._cancelled:
            return
        cdef object cb = self._callback
        cdef tuple args = self._args
        self._callback = None
        self._args = None
        if cb is None:
            return
        try:
            if args is not None:
                self._context.run(cb, *args)
            else:
                self._context.run(cb)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            cb_repr = _format_callback(cb, args)
            self._loop.call_exception_handler({
                'message': 'Exception in callback {}'.format(cb_repr),
                'exception': exc,
                'handle': self,
            })


# ===========================================================================
# The Loop
# ===========================================================================
@cython.no_gc_clear
cdef class Loop:
    """asyncio-compatible event loop driven by libhv's hloop_process_events."""

    cdef:
        hv.hloop_t* hvloop
        object _ready              # collections.deque[Handle]
        set _timer_handles         # live TimerHandles backed by an htimer_t
        set _hio_objs              # live hio wrappers (TCPTransport/_TCPListener/_FDWatcher)
        dict _fd_watchers          # {int fd: _FDWatcher} (add_reader/add_writer, M2b)
        dict _signal_handlers      # {int signum: Handle} (add_signal_handler, M2b)
        object _signal_ssock       # signal wakeup socketpair read end (loop-owned)
        object _signal_csock       # ... write end, installed via set_wakeup_fd
        object _pending_exc        # KI/SE raised inside a libhv C timer callback
        bint _stopping
        bint _closed
        long _thread_id
        bint _debug
        object _exception_handler
        object _default_executor
        bint _executor_shutdown_called
        object _task_factory
        object _asyncgens          # weakref.WeakSet of running async generators
        bint _asyncgens_shutdown_called
        bint _coroutine_origin_tracking_enabled
        object _coroutine_origin_tracking_saved_depth
        double _last_time          # loop.time() snapshot taken at close()
        dict __dict__
        object __weakref__

    def __cinit__(self):
        self.hvloop = hv.hloop_new(0)   # explicit 0: no HLOOP_FLAG_AUTO_FREE
        if self.hvloop is NULL:
            raise RuntimeError('hloop_new failed')
        self._ready = col_deque()
        self._timer_handles = set()
        self._hio_objs = set()
        self._fd_watchers = {}
        self._signal_handlers = {}
        self._signal_ssock = None
        self._signal_csock = None
        self._pending_exc = None
        self._stopping = False
        self._closed = False
        self._thread_id = 0
        self._debug = bool(sys.flags.dev_mode)
        self._exception_handler = None
        self._default_executor = None
        self._executor_shutdown_called = False
        self._task_factory = None
        self._asyncgens = _weakset()
        self._asyncgens_shutdown_called = False
        self._coroutine_origin_tracking_enabled = False
        self._coroutine_origin_tracking_saved_depth = None
        self._last_time = 0.0

    def __dealloc__(self):
        if self.hvloop is not NULL:
            hv.hloop_free(&self.hvloop)
            self.hvloop = NULL

    def __repr__(self):
        return '<{} running={} closed={} debug={}>'.format(
            type(self).__name__, self.is_running(), self.is_closed(),
            self.get_debug())

    # ----- internal helpers ----------------------------------------------
    cdef inline _check_closed(self):
        if self._closed:
            raise RuntimeError('Event loop is closed')

    cdef inline _check_running(self):
        if self.is_running():
            raise RuntimeError('This event loop is already running')
        if aio_get_running_loop() is not None:
            raise RuntimeError(
                'Cannot run the event loop while another loop is running')

    cdef inline _post_wakeup(self):
        # Force/refresh the wakeup eventfd and interrupt any in-progress poll.
        hv.hloop_wakeup(self.hvloop)

    cdef _run_ready(self):
        # Run a snapshot of the ready queue; callbacks scheduled during this
        # turn stay queued for the next turn (prevents starvation), matching
        # asyncio.BaseEventLoop._run_once. The queue holds Handle (call_soon)
        # and occasionally TimerHandle (call_later/call_at with delay <= 0).
        cdef object ready = self._ready
        cdef Py_ssize_t ntodo = len(ready)
        cdef Py_ssize_t i
        cdef object item
        for i in range(ntodo):
            item = ready.popleft()
            if type(item) is Handle:
                (<Handle>item)._run()
            else:
                (<TimerHandle>item)._run()

    # ----- lifecycle ------------------------------------------------------
    def run_forever(self):
        self._check_closed()
        self._check_running()

        cdef int timeout_ms
        old_agen_hooks = sys.get_asyncgen_hooks()
        self._set_coroutine_origin_tracking(self._debug)
        try:
            self._thread_id = threading.get_ident()
            sys.set_asyncgen_hooks(
                firstiter=self._asyncgen_firstiter_hook,
                finalizer=self._asyncgen_finalizer_hook)
            aio_set_running_loop(self)

            # Plan section 4.2: create the wakeup eventfd BEFORE blocking, so a
            # cross-thread call_soon_threadsafe can interrupt the very first poll.
            self._post_wakeup()

            # We self-drive via hloop_process_events instead of hloop_run, so
            # libhv never moves the loop out of its initial HLOOP_STATUS_STOP.
            # In that state hloop_process_events returns right after the poll
            # (hloop.c:170) and skips hloop_process_pendings, so IO callbacks
            # (including the wakeup-fd reader that drains the eventfd) never
            # run and the loop busy-spins. Mirror hloop_run: mark RUNNING here,
            # and STOP again in the finally below. A KeyboardInterrupt/SystemExit
            # path (_timer_dispatch -> hloop_stop) flips status back to STOP to
            # break out promptly; re-entering run_forever() re-arms RUNNING here.
            hv.hvloop_set_status_running(self.hvloop)

            while True:
                self._run_ready()
                if self._stopping:
                    break
                if len(self._ready):
                    timeout_ms = 0
                else:
                    timeout_ms = _MAX_BLOCK_MS
                with nogil:
                    hv.hloop_process_events(self.hvloop, timeout_ms)
                # A timer callback running inside the poll above may have raised
                # KeyboardInterrupt/SystemExit; _timer_dispatch stashes it here
                # (it cannot propagate through the noexcept C callback frame).
                # Re-raise so it leaves run_forever()/run_until_complete().
                if self._pending_exc is not None:
                    exc = self._pending_exc
                    self._pending_exc = None
                    raise exc
        finally:
            # Mirror hloop_run's exit: return the loop to STOP. Guard NULL in
            # case close() (or a teardown path) already freed the loop.
            if self.hvloop is not NULL:
                hv.hvloop_set_status_stop(self.hvloop)
            self._stopping = False
            self._pending_exc = None
            self._thread_id = 0
            aio_set_running_loop(None)
            self._set_coroutine_origin_tracking(False)
            sys.set_asyncgen_hooks(*old_agen_hooks)

    def run_until_complete(self, future):
        self._check_closed()
        self._check_running()

        new_task = not aio_isfuture(future)
        future = aio_ensure_future(future, loop=self)
        if new_task:
            # The caller did not pass a Future/Task; if it raises we don't want
            # an "exception never retrieved" warning.
            future._log_destroy_pending = False

        future.add_done_callback(_run_until_complete_cb)
        try:
            self.run_forever()
        except BaseException:
            if new_task and future.done() and not future.cancelled():
                future.exception()
            raise
        finally:
            future.remove_done_callback(_run_until_complete_cb)
        if not future.done():
            raise RuntimeError('Event loop stopped before Future completed.')
        return future.result()

    def stop(self):
        self._stopping = True
        # If stop() is called from another thread, wake the poll so the loop
        # body re-checks _stopping promptly.
        if self.hvloop is not NULL:
            self._post_wakeup()

    def is_running(self):
        return self._thread_id != 0

    def is_closed(self):
        return self._closed

    def close(self):
        if self.is_running():
            raise RuntimeError('Cannot close a running event loop')
        if self._closed:
            return
        self._closed = True
        # Snapshot the clock so time() keeps returning a sane monotonic value
        # after close instead of jumping back to 0.0 (see time()).
        if self.hvloop is not NULL:
            hv.hloop_update_time(self.hvloop)
            self._last_time = hv.hloop_now_us(self.hvloop) / 1e6
        self._ready.clear()
        # Tear down every still-registered htimer's TimerHandle BEFORE
        # hloop_free. libhv frees the htimer_t* structs in hloop_free without
        # invoking our _on_timer callback, so without this each un-fired timer
        # would leak its registration reference (callback/args kept alive) and a
        # later handle.cancel() would call htimer_del on freed memory. We null
        # each handle's _timer first so a subsequent cancel() takes its t==NULL
        # branch (no htimer_del, no second DECREF). This path is mutually
        # exclusive with _timer_dispatch (loop not running) and cancel().
        cdef TimerHandle th
        if self._timer_handles:
            handles = list(self._timer_handles)
            self._timer_handles.clear()
            for th in handles:
                th._timer = NULL
                th._cancelled = True
                th._callback = None
                th._args = None
                Py_DECREF(th)
        # M2b signal teardown: unregister every signal handler (restoring the
        # default dispositions, asyncio semantics), restore set_wakeup_fd(-1)
        # (only if the installed wakeup fd is still our write end) and close
        # both ends of the socketpair -- the pair is loop-owned. This runs
        # BEFORE the _hio_objs teardown so the pair's read-end watcher is
        # deregistered from the iowatcher while its fd is still open.
        if self._signal_handlers and not sys.is_finalizing():
            for sig in list(self._signal_handlers):
                try:
                    self.remove_signal_handler(sig)
                except (KeyboardInterrupt, SystemExit):
                    raise
                except BaseException as sig_exc:
                    self.call_exception_handler({
                        'message': 'error while removing signal handler {} '
                                   'during loop.close()'.format(sig),
                        'exception': sig_exc,
                    })
        self._teardown_signal_wakeup()
        # Tear down every still-open hio wrapper (transports / server
        # listeners / fd watchers) BEFORE hloop_free. Each teardown nulls the
        # wrapper's hio_t* pointer, clears the C callbacks/context so
        # hloop_free's own hio_close path cannot re-enter Python, releases the
        # registration reference exactly once, and (for caller-owned fds:
        # create_server(sock=..) listeners and add_reader/add_writer watchers)
        # detaches the hio so the caller's fd is NOT closed. Self-owned
        # fds are closed by hloop_free (hio_free -> hio_close -> closesocket).
        # This path is mutually exclusive with the C close-callback dispatch
        # (the loop is not running) and with Server.close()/transport.close()
        # afterwards (they see a NULL hio and return safely).
        if self._hio_objs:
            objs = list(self._hio_objs)
            self._hio_objs.clear()
            for obj in objs:
                try:
                    obj._loop_close_teardown()
                except (KeyboardInterrupt, SystemExit):
                    raise
                except BaseException as teardown_exc:
                    self.call_exception_handler({
                        'message': 'error while tearing down a transport '
                                   'during loop.close()',
                        'exception': teardown_exc,
                    })
        if self._default_executor is not None:
            executor = self._default_executor
            self._default_executor = None
            executor.shutdown(wait=False)
        if self.hvloop is not NULL:
            hv.hloop_free(&self.hvloop)
            self.hvloop = NULL

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ----- time -----------------------------------------------------------
    def time(self):
        if self.hvloop is NULL:
            # After close() the libhv loop is gone; return the monotonic value
            # captured at close() rather than jumping back to 0.0, so time()
            # never appears to run backwards across close.
            return self._last_time
        hv.hloop_update_time(self.hvloop)
        return hv.hloop_now_us(self.hvloop) / 1e6

    # ----- scheduling -----------------------------------------------------
    def call_soon(self, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, 'call_soon')
            self._check_thread()
        return self._call_soon(callback, args, context)

    cdef Handle _call_soon(self, object callback, tuple args, object context):
        cdef Handle handle = Handle(callback, args, self, context)
        self._ready.append(handle)
        return handle

    def call_soon_threadsafe(self, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, 'call_soon_threadsafe')
        cdef Handle handle = Handle(callback, args, self, context)
        # deque.append is atomic under the GIL; safe from any thread.
        self._ready.append(handle)
        # Interrupt the loop's poll (plan section 4.4).
        if self.hvloop is not NULL:
            self._post_wakeup()
        return handle

    def call_later(self, delay, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, 'call_later')
            self._check_thread()
        if delay is None:
            raise TypeError('delay must not be None')
        when = self.time() + delay
        return self._call_at(when, delay, callback, args, context)

    def call_at(self, when, callback, *args, context=None):
        self._check_closed()
        if self._debug:
            self._check_callback(callback, 'call_at')
            self._check_thread()
        if when is None:
            raise TypeError('when must not be None')
        delay = when - self.time()
        return self._call_at(when, delay, callback, args, context)

    cdef object _call_at(self, double when, double delay,
                         object callback, tuple args, object context):
        cdef uint32_t delay_ms
        cdef double delay_ms_d
        if delay <= 0:
            # Non-positive delay: run on the next loop turn. TimerHandle handles
            # delay_ms == 0 by enqueueing itself on the ready queue (libhv's
            # htimer_add rejects 0ms anyway), while still returning a
            # cancellable TimerHandle per the asyncio contract.
            delay_ms = 0
        else:
            # Round UP (ceil), not nearest: asyncio forbids running a callback
            # before its ``when``. Nearest rounding (e.g. 10.4ms -> 10ms) could
            # fire ~0.4ms early; ceil guarantees the htimer fires at or after
            # ``when``. The precision tests assert actual run time >= when.
            delay_ms_d = libc_ceil(delay * 1000.0)
            # Clamp before the uint32_t cast: a huge delay (e.g. 1e9 s) overflows
            # uint32 and the C cast is undefined behaviour. libhv's htimer caps
            # out around 0xffffffff ms (~49.7 days), which is far longer than any
            # real timeout, so clamping to 0xfffffffe is harmless.
            if delay_ms_d >= <double>0xfffffffe:
                delay_ms = <uint32_t>0xfffffffe
            else:
                delay_ms = <uint32_t>delay_ms_d
            if delay_ms == 0:
                # ceil() of a tiny-but-positive delay can still be 0 only if
                # delay*1000 == 0 exactly, which delay > 0 already excludes;
                # guard anyway so a positive delay never degrades to "next turn".
                delay_ms = 1
        return TimerHandle(self, callback, args, delay_ms, when, context)

    def create_future(self):
        return aio_Future(loop=self)

    def create_task(self, coro, *, name=None, context=None):
        self._check_closed()
        if self._task_factory is None:
            if _PY311:
                task = aio_Task(coro, loop=self, name=name, context=context)
            else:
                if context is not None:
                    raise TypeError(
                        "'context' is only supported on Python 3.11+")
                task = aio_Task(coro, loop=self, name=name)
            if task._source_traceback:
                del task._source_traceback[-1]
        else:
            if _PY311 and context is not None:
                task = self._task_factory(self, coro, context=context)
            else:
                task = self._task_factory(self, coro)
            try:
                task.set_name(name)
            except AttributeError:
                pass
        return task

    def set_task_factory(self, factory):
        if factory is not None and not callable(factory):
            raise TypeError('task factory must be a callable or None')
        self._task_factory = factory

    def get_task_factory(self):
        return self._task_factory

    # ----- executor / DNS -------------------------------------------------
    def run_in_executor(self, executor, func, *args):
        self._check_closed()
        if self._debug:
            self._check_callback(func, 'run_in_executor')
        if executor is None:
            executor = self._default_executor
            if executor is None:
                if self._executor_shutdown_called:
                    raise RuntimeError('Executor shutdown has been called')
                executor = concurrent.futures.ThreadPoolExecutor(
                    thread_name_prefix='hvloop')
                self._default_executor = executor
        return asyncio.futures.wrap_future(
            executor.submit(func, *args), loop=self)

    def set_default_executor(self, executor):
        if not isinstance(executor, concurrent.futures.ThreadPoolExecutor):
            raise TypeError(
                'executor must be ThreadPoolExecutor instance')
        self._default_executor = executor

    async def getaddrinfo(self, host, port, *, family=0, type=0, proto=0,
                          flags=0):
        getaddr_func = socket_module.getaddrinfo
        return await self.run_in_executor(
            None, getaddr_func, host, port, family, type, proto, flags)

    async def getnameinfo(self, sockaddr, flags=0):
        return await self.run_in_executor(
            None, socket_module.getnameinfo, sockaddr, flags)

    # ----- sock_* low-level socket operations (plan section 5, M4) ----------
    #
    # Implemented on top of the M2b add_reader/add_writer machinery with the
    # semantics of asyncio's *selector* event loop: the socket must be
    # non-blocking (validated in debug mode, exactly like asyncio), the fd
    # stays owned by the caller, and each pending operation registers a
    # temporary reader/writer that is removed when its future completes
    # (including cancellation).
    #
    # CONSTRAINTS (documented, not enforced -- same as add_reader/add_writer,
    # see the fd-watching section): a socket used with sock_* must not
    # simultaneously (a) be owned by a transport/server listener of this
    # loop, or (b) carry a user add_reader/add_writer registration in the
    # same direction -- the sock_* operation and the user callback would
    # replace each other's registration (asyncio's selector loop raises for
    # case (a) and silently replaces in case (b); we document both). Also
    # note libhv flips watched socket fds to non-blocking mode.

    async def sock_recv(self, sock, n):
        """Receive up to ``n`` bytes from ``sock`` (a non-blocking socket)."""
        _check_ssl_socket(sock)
        if self._debug and sock.gettimeout() != 0:
            raise ValueError('the socket must be non-blocking')
        try:
            return sock.recv(n)
        except (BlockingIOError, InterruptedError):
            pass
        fut = self.create_future()
        fd = sock.fileno()
        self.add_reader(fd, self._sock_recv_cb, fut, sock, n)
        fut.add_done_callback(lambda f: self.remove_reader(fd))
        return await fut

    def _sock_recv_cb(self, fut, sock, n):
        if fut.done():
            return
        try:
            data = sock.recv(n)
        except (BlockingIOError, InterruptedError):
            return      # spurious readiness; wait for the next event
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(data)

    async def sock_recv_into(self, sock, buf):
        """Receive into ``buf``; returns the number of bytes received."""
        _check_ssl_socket(sock)
        if self._debug and sock.gettimeout() != 0:
            raise ValueError('the socket must be non-blocking')
        try:
            return sock.recv_into(buf)
        except (BlockingIOError, InterruptedError):
            pass
        fut = self.create_future()
        fd = sock.fileno()
        self.add_reader(fd, self._sock_recv_into_cb, fut, sock, buf)
        fut.add_done_callback(lambda f: self.remove_reader(fd))
        return await fut

    def _sock_recv_into_cb(self, fut, sock, buf):
        if fut.done():
            return
        try:
            nbytes = sock.recv_into(buf)
        except (BlockingIOError, InterruptedError):
            return
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(nbytes)

    async def sock_sendall(self, sock, data):
        """Send ``data`` to ``sock``, retrying until everything is sent."""
        _check_ssl_socket(sock)
        if self._debug and sock.gettimeout() != 0:
            raise ValueError('the socket must be non-blocking')
        try:
            n = sock.send(data)
        except (BlockingIOError, InterruptedError):
            n = 0
        if n == len(data):
            # Common case: everything went out in one non-blocking send.
            return
        fut = self.create_future()
        fd = sock.fileno()
        # pos is a 1-element list so the writer callback can advance it.
        pos = [n]
        self.add_writer(fd, self._sock_sendall_cb, fut, sock,
                        memoryview(data), pos)
        fut.add_done_callback(lambda f: self.remove_writer(fd))
        return await fut

    def _sock_sendall_cb(self, fut, sock, view, pos):
        if fut.done():
            return
        start = pos[0]
        try:
            n = sock.send(view[start:])
        except (BlockingIOError, InterruptedError):
            return
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
            return
        start += n
        if start == len(view):
            fut.set_result(None)
        else:
            pos[0] = start

    async def sock_connect(self, sock, address):
        """Connect ``sock`` (non-blocking) to ``address``."""
        _check_ssl_socket(sock)
        if self._debug and sock.gettimeout() != 0:
            raise ValueError('the socket must be non-blocking')
        if (sock.family == _AF_INET or sock.family == _AF_INET6):
            # Resolve the address first (asyncio's _ensure_resolved:
            # numeric fast path, else getaddrinfo in the executor).
            address = await self._sock_resolve(sock, address)
        fut = self.create_future()
        fd = sock.fileno()
        try:
            sock.connect(address)
        except (BlockingIOError, InterruptedError):
            # Connect in progress: the fd turns writable when it completes
            # (level-triggered wepoll/epoll/kqueue all report this).
            self.add_writer(fd, self._sock_connect_cb, fut, sock, address)
            fut.add_done_callback(lambda f: self.remove_writer(fd))
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)
        return await fut

    async def _sock_resolve(self, sock, address):
        host, port = address[:2]
        if _ipaddr_info is not None:
            info = _ipaddr_info(host, port, sock.family, sock.type,
                                sock.proto, *address[2:])
            if info is not None:
                return info[4]
        infos = await self.getaddrinfo(host, port, family=sock.family,
                                       type=sock.type, proto=sock.proto)
        if not infos:
            raise OSError('getaddrinfo() returned empty list')
        return infos[0][4]

    def _sock_connect_cb(self, fut, sock, address):
        if fut.done():
            return
        try:
            err = sock.getsockopt(socket_module.SOL_SOCKET,
                                  socket_module.SO_ERROR)
            if err != 0:
                # Jump to the except clause below (mirrors asyncio).
                raise OSError(err, 'Connect call failed {}'.format(address))
        except (BlockingIOError, InterruptedError):
            pass        # not connected yet; retry on the next writability
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
        else:
            fut.set_result(None)

    async def sock_accept(self, sock):
        """Accept a connection on listening ``sock`` (non-blocking).

        Returns (conn, address); ``conn`` is set non-blocking.
        """
        _check_ssl_socket(sock)
        if self._debug and sock.gettimeout() != 0:
            raise ValueError('the socket must be non-blocking')
        try:
            conn, address = sock.accept()
        except (BlockingIOError, InterruptedError):
            pass
        else:
            conn.setblocking(False)
            return conn, address
        fut = self.create_future()
        fd = sock.fileno()
        self.add_reader(fd, self._sock_accept_cb, fut, sock)
        fut.add_done_callback(lambda f: self.remove_reader(fd))
        return await fut

    def _sock_accept_cb(self, fut, sock):
        if fut.done():
            return
        try:
            conn, address = sock.accept()
            conn.setblocking(False)
        except (BlockingIOError, InterruptedError):
            return
        except (SystemExit, KeyboardInterrupt):
            raise
        except BaseException as exc:
            fut.set_exception(exc)
        else:
            fut.set_result((conn, address))

    # ----- fd watching: add_reader / add_writer (plan section 5, M2b) ------
    #
    # Implementation note: hio_add(io, cb, events) REPLACES the io's
    # event-dispatch callback (hloop.c: io->cb = cb; the high-level API puts
    # nio.c's hio_handle_events there), so with our raw __fd_watcher_cb libhv
    # never reads/writes the fd itself -- we only translate level-triggered
    # readiness into the registered callbacks. Constraints (documented, not
    # enforced): an fd watched here must not simultaneously be owned by a
    # transport/server listener of this loop, and libhv's high-level
    # hio_read/hio_write API must not be used on a watched fd.

    def add_reader(self, fd, callback, *args):
        """Start watching ``fd`` for readability.

        ``callback(*args)`` runs on every loop turn in which the fd is
        readable (level-triggered), in a context captured at registration
        time (contextvars.copy_context, asyncio semantics). ``fd`` is an int
        or any object with a ``fileno()`` method. Re-registering an fd that
        already has a reader replaces the previous callback.

        The fd stays owned by the caller: remove_reader()/loop.close() only
        unregister it from libhv and never close it. NOTE: libhv flips
        watched socket fds to non-blocking mode (hio_ready).
        """
        self._check_closed()
        self._fd_watch_add(_fileobj_to_fd(fd), hv.HV_READ, callback, args)

    def remove_reader(self, fd):
        """Stop watching ``fd`` for readability.

        Returns True if a reader callback was registered, False otherwise.
        The fd itself is never closed and remains usable by the caller.
        """
        if self._closed:
            return False
        return self._fd_watch_remove(_fileobj_to_fd(fd), hv.HV_READ)

    def add_writer(self, fd, callback, *args):
        """Start watching ``fd`` for writability.

        ``callback(*args)`` runs on every loop turn in which the fd is
        writable; the libhv poll backends are level-triggered, so the
        callback keeps firing while the fd stays writable (asyncio
        semantics). See add_reader() for fd ownership and constraints.
        """
        self._check_closed()
        self._fd_watch_add(_fileobj_to_fd(fd), hv.HV_WRITE, callback, args)

    def remove_writer(self, fd):
        """Stop watching ``fd`` for writability.

        Returns True if a writer callback was registered, False otherwise.
        The fd itself is never closed and remains usable by the caller.
        """
        if self._closed:
            return False
        return self._fd_watch_remove(_fileobj_to_fd(fd), hv.HV_WRITE)

    cdef _fd_watch_add(self, int fd, int events, object callback, tuple args):
        cdef _FDWatcher w
        cdef object existing = self._fd_watchers.get(fd)
        if existing is None:
            w = _FDWatcher.new(self, fd)
        else:
            w = <_FDWatcher>existing
        try:
            w._add(events, callback, args)
        except BaseException:
            # A freshly created (or now-empty) watcher must not stay
            # registered without any callback slot.
            if w._reader is None and w._writer is None:
                w._teardown()
            raise

    cdef bint _fd_watch_remove(self, int fd, int events):
        cdef object existing = self._fd_watchers.get(fd)
        if existing is None:
            return False
        return (<_FDWatcher>existing)._remove(events)

    # ----- Unix signals (plan section 9, M2b) -------------------------------
    #
    # CPython's C-level signal handler writes the signal number to a
    # non-blocking socketpair write end installed via signal.set_wakeup_fd();
    # the read end is watched with the M2b fd machinery above, and arriving
    # signal numbers dispatch the registered (persistent) Handle onto the
    # ready queue. A Python-level no-op handler keeps the C-level handler
    # installed (SIG_DFL/SIG_IGN would bypass the wakeup-fd write entirely).

    def add_signal_handler(self, sig, callback, *args):
        """Register ``callback(*args)`` to run on Unix signal ``sig``.

        Main thread only (a signal.set_wakeup_fd restriction, surfaced as
        RuntimeError, same as asyncio). Windows: NotImplementedError.
        """
        cdef Handle handle
        if _IS_WINDOWS:
            raise NotImplementedError(
                'add_signal_handler() is not supported on Windows')
        if (aio_iscoroutine(callback) or
                _iscoroutinefunction(callback)):
            raise TypeError(
                'coroutines cannot be used with add_signal_handler()')
        self._check_signal(sig)
        self._check_closed()
        # Installs (or refreshes) the wakeup fd; RuntimeError when not on the
        # main thread.
        self._ensure_signal_wakeup()
        handle = Handle(callback, args, self, None)
        handle._repeat = True   # one Handle runs once per signal delivery
        self._signal_handlers[sig] = handle
        try:
            signal_module.signal(sig, _sighandler_noop)
            # Don't let the signal interrupt blocking syscalls (asyncio does
            # the same; the wakeup fd already interrupts our poll).
            signal_module.siginterrupt(sig, False)
        except OSError as exc:
            del self._signal_handlers[sig]
            if not self._signal_handlers:
                self._reset_wakeup_fd()
            if exc.errno == errno_module.EINVAL:
                raise RuntimeError(
                    'sig {} cannot be caught'.format(sig)) from None
            raise

    def remove_signal_handler(self, sig):
        """Remove the handler for ``sig``; returns True if one was set.

        asyncio semantics: the disposition is restored to
        signal.default_int_handler for SIGINT and signal.SIG_DFL otherwise.
        """
        if _IS_WINDOWS:
            raise NotImplementedError(
                'remove_signal_handler() is not supported on Windows')
        self._check_signal(sig)
        try:
            del self._signal_handlers[sig]
        except KeyError:
            return False
        if sig == signal_module.SIGINT:
            handler = signal_module.default_int_handler
        else:
            handler = signal_module.SIG_DFL
        try:
            signal_module.signal(sig, handler)
        except OSError as exc:
            if exc.errno == errno_module.EINVAL:
                raise RuntimeError(
                    'sig {} cannot be caught'.format(sig)) from None
            raise
        if not self._signal_handlers:
            self._reset_wakeup_fd()
        return True

    cdef _check_signal(self, sig):
        if not isinstance(sig, int):
            raise TypeError('sig must be an int, not {!r}'.format(sig))
        if sig not in signal_module.valid_signals():
            raise ValueError('invalid signal number {}'.format(sig))

    cdef _ensure_signal_wakeup(self):
        # Lazily create the non-blocking wakeup socketpair, watch its read
        # end with the fd machinery, and (re-)install its write end as the
        # interpreter's signal wakeup fd.
        cdef bint created = False
        if self._signal_ssock is None:
            ssock, csock = socket_module.socketpair()
            ssock.setblocking(False)
            csock.setblocking(False)
            created = True
        else:
            ssock = self._signal_ssock
            csock = self._signal_csock
        try:
            # ValueError when not on the main thread.
            signal_module.set_wakeup_fd(csock.fileno())
        except (ValueError, OSError) as exc:
            if created:
                ssock.close()
                csock.close()
            raise RuntimeError(str(exc)) from None
        if created:
            self._signal_ssock = ssock
            self._signal_csock = csock
            try:
                self._fd_watch_add(ssock.fileno(), hv.HV_READ,
                                   self._on_signal_wakeup, ())
            except BaseException:
                self._teardown_signal_wakeup()
                raise

    cdef _reset_wakeup_fd(self):
        # Restore set_wakeup_fd(-1), but only if the installed wakeup fd is
        # still our write end; if someone else installed their own in the
        # meantime, put theirs back untouched.
        if self._signal_csock is None:
            return
        try:
            fd = signal_module.set_wakeup_fd(-1)
            if fd != -1 and fd != self._signal_csock.fileno():
                signal_module.set_wakeup_fd(fd)
        except (ValueError, OSError) as exc:
            aio_logger.info('set_wakeup_fd(-1) failed: %s', exc)

    cdef _teardown_signal_wakeup(self):
        # Restore the wakeup fd, unwatch the read end and close both ends of
        # the socketpair (the pair is loop-owned). The unwatch must happen
        # while the read end is still open so the iowatcher deregistration
        # (kqueue/epoll DEL on the fd) succeeds.
        ssock = self._signal_ssock
        csock = self._signal_csock
        if ssock is None:
            return
        self._reset_wakeup_fd()
        self._signal_ssock = None
        self._signal_csock = None
        self._fd_watch_remove(ssock.fileno(), hv.HV_READ)
        ssock.close()
        csock.close()

    def _on_signal_wakeup(self):
        # Persistent reader callback on the wakeup socketpair's read end;
        # runs in the loop thread. Drain the pair, dispatch per signo.
        ssock = self._signal_ssock
        if ssock is None:
            return
        while True:
            try:
                data = ssock.recv(4096)
            except InterruptedError:
                continue
            except OSError:
                # BlockingIOError: drained. Anything else: nothing useful to
                # do from here; the loop keeps running.
                return
            if not data:
                return
            for signum in data:
                if not signum:
                    continue
                self._dispatch_signal(signum)

    cdef _dispatch_signal(self, int signum):
        handle = self._signal_handlers.get(signum)
        if handle is None:
            return
        if (<Handle>handle)._cancelled:
            self.remove_signal_handler(signum)
        else:
            # The Handle is persistent (_repeat): _run_ready executes it
            # without consuming callback/args (plan section 9).
            self._ready.append(handle)

    # ----- TCP: create_connection / create_server (plan sections 6 & 7) ----
    cdef TCPTransport _tcp_wrap_fd(self, int fd):
        # Wrap an OS-level fd (already detached from any Python socket; libhv
        # owns it from here on and hio_close will close it) in a TCPTransport.
        cdef hv.hio_t* io = hv.hio_get(self.hvloop, fd)
        if io is NULL:
            try:
                # socket.close(fd), not os.close(fd): on Windows the fd is a
                # raw SOCKET handle, not a CRT fd (M4 Windows portability).
                socket_module.close(fd)
            except OSError:
                pass
            raise RuntimeError('hio_get() failed for fd {}'.format(fd))
        return TCPTransport.new(self, None, None, io)

    async def _tcp_connect(self, object sock, object address):
        """Detach ``sock``, hand its fd to libhv and connect to ``address``.

        Returns a connected TCPTransport in pre-init state (no protocol yet).
        Connect errors surface through the hio close callback (nio.c routes
        failed connects to hio_close), which fails the waiter future.
        """
        cdef int fd = sock.detach()
        cdef TCPTransport tr = self._tcp_wrap_fd(fd)
        cdef hv.sockaddr_u paddr
        memset(<void*>&paddr, 0, sizeof(paddr))
        host = address[0]
        port = address[1]
        if hv.sockaddr_set_ipport(&paddr, host.encode('ascii'), port) != 0:
            # Fresh self-owned fd: hio_close closes it (no callbacks set yet
            # beyond ours, which tolerate the pre-protocol state).
            tr._teardown_failed_connect()
            raise OSError('invalid remote address {!r}'.format(address))
        hv.hio_set_peeraddr(tr._hio, <hv.sockaddr*>&paddr,
                            hv.sockaddr_len(&paddr))
        waiter = self.create_future()
        tr._waiter = waiter
        hv.hio_setcb_connect(tr._hio, __tcp_connect_cb)
        hv.hio_set_connect_timeout(tr._hio, _HV_CONNECT_TIMEOUT_MS)
        # On immediate failure hio_connect schedules an async close; the close
        # dispatch then fails the waiter, so we always just await it.
        hv.hio_connect(tr._hio)
        try:
            await waiter
        except BaseException:
            # OSError from the close dispatch, or CancelledError from the
            # caller. Tear down the half-open connection; there is no protocol
            # yet, so the close dispatch only cleans up.
            tr._teardown_failed_connect()
            raise
        return tr

    async def create_connection(self, protocol_factory, host=None, port=None,
                                *, ssl=None, family=0, proto=0, flags=0,
                                sock=None, local_addr=None,
                                server_hostname=None,
                                ssl_handshake_timeout=None,
                                ssl_shutdown_timeout=None,
                                happy_eyeballs_delay=None, interleave=None,
                                all_errors=False):
        """Connect to a TCP server (plan section 6).

        Multiple resolved addresses are tried sequentially (no
        happy-eyeballs), matching the plan.

        TLS (M4, plan section 8): ``ssl`` may be True (default client
        context) or an ssl.SSLContext. The raw TCPTransport then carries the
        ciphertext for a stdlib asyncio.sslproto.SSLProtocol and the caller
        receives (ssl_app_transport, protocol) -- exactly the structure of
        asyncio.BaseEventLoop._make_ssl_transport.
        """
        self._check_closed()
        if server_hostname is not None and not ssl:
            raise ValueError(
                'server_hostname is only meaningful with ssl')
        if server_hostname is None and ssl:
            # asyncio semantics: default server_hostname to host; using
            # ssl with sock= (no host) requires an explicit server_hostname.
            if not host:
                raise ValueError('You must set server_hostname '
                                 'when using ssl without a host')
            server_hostname = host
        if ssl_handshake_timeout is not None and not ssl:
            raise ValueError(
                'ssl_handshake_timeout is only meaningful with ssl')
        if ssl_shutdown_timeout is not None and not ssl:
            raise ValueError(
                'ssl_shutdown_timeout is only meaningful with ssl')
        if ssl_shutdown_timeout is not None and not _PY311:
            raise TypeError(
                'ssl_shutdown_timeout requires Python 3.11+ '
                '(pre-3.11 asyncio.sslproto has no such parameter)')
        if sock is not None:
            _check_ssl_socket(sock)

        cdef TCPTransport tr = None

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the '
                    'same time')
            infos = await self.getaddrinfo(
                host, port, family=family, type=socket_module.SOCK_STREAM,
                proto=proto, flags=flags)
            if not infos:
                raise OSError('getaddrinfo() returned empty list')
            laddr_infos = None
            if local_addr is not None:
                laddr_infos = await self.getaddrinfo(
                    *local_addr, family=family,
                    type=socket_module.SOCK_STREAM, proto=proto, flags=flags)
                if not laddr_infos:
                    raise OSError('getaddrinfo() returned empty list')

            exceptions = []
            for af, socktype, protonum, _cname, address in infos:
                try:
                    s = socket_module.socket(af, socktype, protonum)
                except OSError as exc:
                    exceptions.append(exc)
                    continue
                s.setblocking(False)
                if laddr_infos is not None:
                    bound = False
                    for _, _, _, _, laddr in laddr_infos:
                        try:
                            s.bind(laddr)
                            bound = True
                            break
                        except OSError as exc:
                            msg = ('error while attempting to bind on '
                                   'address {!r}: {}'.format(
                                       laddr, exc.strerror.lower()))
                            exceptions.append(OSError(exc.errno, msg))
                    if not bound:
                        s.close()
                        continue
                try:
                    tr = await self._tcp_connect(s, address)
                    break
                except OSError as exc:
                    exceptions.append(exc)
                    tr = None
            if tr is None:
                if all_errors:
                    raise ExceptionGroup('create_connection failed',
                                         exceptions)
                if len(exceptions) == 1:
                    raise exceptions[0]
                model = str(exceptions[0])
                if all(str(exc) == model for exc in exceptions):
                    raise exceptions[0]
                raise OSError('Multiple exceptions: {}'.format(
                    ', '.join(str(exc) for exc in exceptions)))
        else:
            if sock is None:
                raise ValueError(
                    'host and port was not specified and no sock specified')
            if sock.type != socket_module.SOCK_STREAM:
                raise ValueError(
                    'A Stream Socket was expected, got {!r}'.format(sock))
            # asyncio semantics: the transport takes ownership of an
            # already-connected sock; detach moves the fd to libhv, which
            # closes it on transport close.
            sock.setblocking(False)
            tr = self._tcp_wrap_fd(sock.detach())

        if tr._hio is NULL:
            # The connection dropped between connect success and now.
            raise ConnectionResetError(
                errno_module.ECONNRESET, 'Connection lost during handshake')
        try:
            protocol = protocol_factory()
        except BaseException:
            tr._teardown_failed_connect()
            raise
        if ssl:
            # Same structure as asyncio's _make_ssl_transport: SSLProtocol
            # becomes the raw transport's protocol, the caller gets the
            # SSL app-transport; the waiter completes when the handshake
            # does (or fails).
            sslcontext = None if isinstance(ssl, bool) else ssl
            waiter = self.create_future()
            try:
                ssl_protocol = _make_ssl_protocol(
                    self, protocol, sslcontext, waiter, False,
                    server_hostname, ssl_handshake_timeout,
                    ssl_shutdown_timeout)
                app_transport = _ssl_app_transport(ssl_protocol)
            except BaseException:
                tr._teardown_failed_connect()
                raise
            tr._protocol = ssl_protocol
            tr._initialize()
            try:
                await waiter
            except BaseException:
                # Handshake failure/cancellation: SSLProtocol._fatal_error
                # already force-closed the raw transport in the failure case;
                # closing the (captured) app transport covers cancellation
                # and is a no-op when the connection is already lost.
                app_transport.close()
                raise
            return app_transport, protocol
        tr._protocol = protocol
        tr._initialize()
        return tr, protocol

    async def create_server(self, protocol_factory, host=None, port=None, *,
                            family=socket_module.AF_UNSPEC,
                            flags=socket_module.AI_PASSIVE,
                            sock=None, backlog=100, ssl=None,
                            reuse_address=None, reuse_port=None,
                            keep_alive=None,
                            ssl_handshake_timeout=None,
                            ssl_shutdown_timeout=None,
                            start_serving=True):
        """Create a TCP server (plan section 7).

        host/port path: hvloop builds the listen sockets in Python (multi
        address getaddrinfo, SO_REUSEADDR/SO_REUSEPORT, IPV6_V6ONLY), then
        sock.detach() hands each fd to libhv, which owns and closes it.
        sock= path: the fd stays owned by the caller's socket object;
        Server.close()/loop.close() only unregister it from libhv.

        ssl= (M4, plan section 8): an ssl.SSLContext wraps every accepted
        connection in asyncio.sslproto.SSLProtocol; the application protocol
        sees the SSL app-transport.
        """
        self._check_closed()
        if isinstance(ssl, bool):
            raise TypeError('ssl argument must be an SSLContext or None')
        if ssl_handshake_timeout is not None and ssl is None:
            raise ValueError(
                'ssl_handshake_timeout is only meaningful with ssl')
        if ssl_shutdown_timeout is not None and ssl is None:
            raise ValueError(
                'ssl_shutdown_timeout is only meaningful with ssl')
        if ssl_shutdown_timeout is not None and not _PY311:
            raise TypeError(
                'ssl_shutdown_timeout requires Python 3.11+ '
                '(pre-3.11 asyncio.sslproto has no such parameter)')
        if sock is not None:
            _check_ssl_socket(sock)

        cdef Server server
        cdef _TCPListener listener

        if host is not None or port is not None:
            if sock is not None:
                raise ValueError(
                    'host/port and sock can not be specified at the '
                    'same time')
            if reuse_address is None:
                reuse_address = os.name == 'posix' and sys.platform != 'cygwin'
            sockets = []
            if host == '':
                hosts = [None]
            elif (isinstance(host, str) or
                    not isinstance(host, collections.abc.Iterable)):
                hosts = [host]
            else:
                hosts = list(host)

            infos = set()
            for h in hosts:
                infos.update(await self.getaddrinfo(
                    h, port, family=family, type=socket_module.SOCK_STREAM,
                    flags=flags))

            completed = False
            try:
                for af, socktype, protonum, _cname, sa in infos:
                    try:
                        s = socket_module.socket(af, socktype, protonum)
                    except OSError:
                        # Assume it's a bad family/type/protocol combination.
                        continue
                    sockets.append(s)
                    if reuse_address:
                        s.setsockopt(socket_module.SOL_SOCKET,
                                     socket_module.SO_REUSEADDR, True)
                    if reuse_port:
                        _set_reuseport(s)
                    if keep_alive:
                        s.setsockopt(socket_module.SOL_SOCKET,
                                     socket_module.SO_KEEPALIVE, True)
                    # Disable IPv4/IPv6 dual stack support (enabled by
                    # default on Linux) which makes a single socket listen on
                    # both address families (same as asyncio).
                    if (af == socket_module.AF_INET6 and
                            hasattr(socket_module, 'IPV6_V6ONLY')):
                        s.setsockopt(socket_module.IPPROTO_IPV6,
                                     socket_module.IPV6_V6ONLY, True)
                    try:
                        s.bind(sa)
                    except OSError as err:
                        msg = ('error while attempting to bind on address '
                               '{!r}: {}'.format(sa, err.strerror.lower()))
                        raise OSError(err.errno, msg) from None
                completed = True
            finally:
                if not completed:
                    for s in sockets:
                        s.close()

            server = Server.new(self, protocol_factory, backlog,
                                ssl, ssl_handshake_timeout,
                                ssl_shutdown_timeout)
            for s in sockets:
                # NOTE: deviation from asyncio: listen() happens here rather
                # than in start_serving(), because the fd is detached to
                # libhv right away and the Python socket object goes away.
                # With start_serving=False the socket is therefore already
                # listening (connections queue in the backlog) but no accept
                # callbacks run until start_serving().
                s.setblocking(False)
                s.listen(backlog)
                listener = _TCPListener.new(self, server, s.detach(), None)
                server._add_listener(listener)
        else:
            if sock is None:
                raise ValueError(
                    'Neither host/port nor sock were specified')
            if sock.type != socket_module.SOCK_STREAM:
                raise ValueError(
                    'A Stream Socket was expected, got {!r}'.format(sock))
            sock.setblocking(False)
            server = Server.new(self, protocol_factory, backlog,
                                ssl, ssl_handshake_timeout,
                                ssl_shutdown_timeout)
            # Caller-owned fd: keep the Python socket object alive on the
            # listener; teardown only unregisters from libhv (plan section 7).
            listener = _TCPListener.new(self, server, sock.fileno(), sock)
            server._add_listener(listener)

        if start_serving:
            server._start_serving()
        return server

    async def shutdown_default_executor(self, timeout=None):
        self._executor_shutdown_called = True
        if self._default_executor is None:
            return
        future = self.create_future()
        thread = threading.Thread(target=self._do_shutdown, args=(future,))
        thread.start()
        try:
            await future
        finally:
            thread.join(timeout)
        if thread.is_alive():
            import warnings
            warnings.warn(
                'The executor did not finishing joining its threads '
                'within %s seconds.' % timeout,
                RuntimeWarning, stacklevel=2)
            self._default_executor.shutdown(wait=False)

    def _do_shutdown(self, future):
        try:
            self._default_executor.shutdown(wait=True)
            if not self.is_closed():
                self.call_soon_threadsafe(_set_result_unless_cancelled,
                                          future, None)
        except Exception as ex:  # noqa: BLE001
            if not self.is_closed() and not future.cancelled():
                self.call_soon_threadsafe(future.set_exception, ex)

    # ----- async generators ----------------------------------------------
    def _asyncgen_firstiter_hook(self, agen):
        if self._asyncgens_shutdown_called:
            import warnings
            warnings.warn(
                'asynchronous generator %r was scheduled after '
                'loop.shutdown_asyncgens() call' % agen,
                ResourceWarning, source=self)
        self._asyncgens.add(agen)

    def _asyncgen_finalizer_hook(self, agen):
        self._asyncgens.discard(agen)
        if not self.is_closed():
            self.call_soon_threadsafe(self.create_task, agen.aclose())

    async def shutdown_asyncgens(self):
        self._asyncgens_shutdown_called = True
        if not len(self._asyncgens):
            return
        closing_agens = list(self._asyncgens)
        self._asyncgens.clear()
        results = await asyncio.gather(
            *[ag.aclose() for ag in closing_agens],
            return_exceptions=True)
        for result, agen in zip(results, closing_agens):
            if isinstance(result, Exception):
                self.call_exception_handler({
                    'message': 'an error occurred during closing of '
                               'asynchronous generator {!r}'.format(agen),
                    'exception': result,
                    'asyncgen': agen,
                })

    # ----- debug ----------------------------------------------------------
    def get_debug(self):
        return self._debug

    def set_debug(self, enabled):
        self._debug = bool(enabled)

    cdef _set_coroutine_origin_tracking(self, bint enabled):
        if bool(enabled) == self._coroutine_origin_tracking_enabled:
            return
        if enabled:
            self._coroutine_origin_tracking_saved_depth = (
                sys.get_coroutine_origin_tracking_depth())
            sys.set_coroutine_origin_tracking_depth(
                constants_DEBUG_STACK_DEPTH)
        else:
            sys.set_coroutine_origin_tracking_depth(
                self._coroutine_origin_tracking_saved_depth)
        self._coroutine_origin_tracking_enabled = enabled

    cdef inline _check_callback(self, object callback, str method):
        if (aio_iscoroutine(callback) or
                _iscoroutinefunction(callback)):
            raise TypeError(
                "coroutines cannot be used with {}()".format(method))
        if not callable(callback):
            raise TypeError(
                'a callable object was expected by {}(), got {!r}'.format(
                    method, callback))

    cdef inline _check_thread(self):
        if self._thread_id == 0:
            return
        cdef long thread_id = threading.get_ident()
        if thread_id != self._thread_id:
            raise RuntimeError(
                'Non-thread-safe operation invoked on an event loop other '
                'than the current one')

    # ----- exception handling --------------------------------------------
    def get_exception_handler(self):
        return self._exception_handler

    def set_exception_handler(self, handler):
        if handler is not None and not callable(handler):
            raise TypeError(
                'A callable object or None is expected, got {!r}'.format(
                    handler))
        self._exception_handler = handler

    def default_exception_handler(self, context):
        message = context.get('message')
        if not message:
            message = 'Unhandled exception in event loop'

        exception = context.get('exception')
        if exception is not None:
            exc_info = (type(exception), exception, exception.__traceback__)
        else:
            exc_info = False

        log_lines = [message]
        for key in sorted(context):
            if key in {'message', 'exception'}:
                continue
            value = context[key]
            if key == 'source_traceback':
                tb = ''.join(traceback.format_list(value))
                value = 'Object created at (most recent call last):\n'
                value += tb.rstrip()
            elif key == 'handle_traceback':
                tb = ''.join(traceback.format_list(value))
                value = 'Handle created at (most recent call last):\n'
                value += tb.rstrip()
            else:
                try:
                    value = repr(value)
                except Exception as ex:  # noqa: BLE001
                    value = ('Exception in __repr__ {!r}; '
                             'value type: {!r}'.format(ex, type(value)))
            log_lines.append('{}: {}'.format(key, value))

        logger = asyncio.log.logger
        logger.error('\n'.join(log_lines), exc_info=exc_info)

    def call_exception_handler(self, context):
        if self._exception_handler is None:
            try:
                self.default_exception_handler(context)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException:
                asyncio.log.logger.error(
                    'Exception in default exception handler',
                    exc_info=True)
            return
        try:
            self._exception_handler(self, context)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            try:
                self.default_exception_handler({
                    'message': 'Unhandled error in exception handler',
                    'exception': exc,
                    'context': context,
                })
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException:
                asyncio.log.logger.error(
                    'Exception in default exception handler '
                    'while handling an unexpected error '
                    'in custom exception handler',
                    exc_info=True)

    # ----- asyncio infrastructure hooks -----------------------------------
    def _timer_handle_cancelled(self, handle):
        # asyncio.Future/Task call this when a TimerHandle is cancelled. With
        # libhv we delete the htimer eagerly in TimerHandle.cancel(), so this
        # is a no-op (kept for interface compatibility).
        pass


# ===========================================================================
# Module-level helpers
# ===========================================================================
cdef object _run_until_complete_cb(fut):
    if not fut.cancelled():
        exc = fut.exception()
        if isinstance(exc, (SystemExit, KeyboardInterrupt)):
            # Don't stop the loop on these; let run_forever propagate them.
            return
    loop = fut.get_loop()
    loop.stop()


cdef _set_result_unless_cancelled(fut, result):
    if fut.cancelled():
        return
    fut.set_result(result)


cdef object _format_callback(object cb, object args):
    return _format_callback_source(cb, args)


# ---------------------------------------------------------------------------
# Imports / fallbacks resolved at import time (kept out of hot paths).
# ---------------------------------------------------------------------------
import contextvars as _contextvars
import weakref as _weakref_module
from asyncio import format_helpers as _format_helpers
from asyncio import coroutines as _aio_coroutines
from asyncio import constants as _aio_constants

cdef object copy_context = _contextvars.copy_context
cdef object _weakset = _weakref_module.WeakSet
# Python 3.14 deprecated the public asyncio.coroutines.iscoroutinefunction
# (a DeprecationWarning per call); the stdlib's own event loops use the
# private _iscoroutinefunction instead. Prefer it when available.
cdef object _iscoroutinefunction = getattr(
    _aio_coroutines, '_iscoroutinefunction',
    _aio_coroutines.iscoroutinefunction)
cdef object _format_callback_source = _format_helpers._format_callback_source
cdef int constants_DEBUG_STACK_DEPTH = _aio_constants.DEBUG_STACK_DEPTH


cdef object aio_get_running_loop():
    try:
        return asyncio.get_running_loop()
    except RuntimeError:
        return None


# ===========================================================================
# TCP transport / server (M2a, plan sections 6 & 7)
# ===========================================================================
cdef object aio_logger = asyncio.log.logger


# ----- TLS (M4, plan section 8) ---------------------------------------------
# Strategy: reuse the stdlib's asyncio.sslproto.SSLProtocol (MemoryBIO based,
# same approach as uvloop). Our TCPTransport carries the raw ciphertext and
# the SSLProtocol sits between it and the application protocol; the caller
# gets SSLProtocol's _app_transport. libhv's own OpenSSL integration stays
# disabled (WITH_OPENSSL=OFF): it cannot consume Python ssl.SSLContext
# objects and would burden the wheels with an OpenSSL link dependency.
import ssl as ssl_module
from asyncio import sslproto as aio_sslproto

cdef object _SSLSocket = ssl_module.SSLSocket
cdef object _SSLProtocol = aio_sslproto.SSLProtocol
cdef object aio_BufferedProtocol = asyncio.BufferedProtocol

# _ipaddr_info: asyncio-private fast path that skips getaddrinfo for numeric
# addresses (used by sock_connect, same as asyncio's _ensure_resolved).
from asyncio import base_events as _aio_base_events
cdef object _ipaddr_info = getattr(_aio_base_events, '_ipaddr_info', None)


cdef _check_ssl_socket(object sock):
    # asyncio semantics: ssl.SSLSocket objects are never acceptable for
    # transport/sock_* APIs (they wrap their own blocking state machine).
    if isinstance(sock, _SSLSocket):
        raise TypeError('Socket cannot be of type SSLSocket')


cdef object _make_ssl_protocol(Loop loop, object app_protocol,
                               object sslcontext, object waiter,
                               bint server_side, object server_hostname,
                               object ssl_handshake_timeout,
                               object ssl_shutdown_timeout):
    # Version gate (plan section 8 / M4): Python 3.11 rewrote asyncio.sslproto
    # (SSLProtocol became a BufferedProtocol with an explicit state machine)
    # and added the ssl_shutdown_timeout parameter. The 3.10 SSLProtocol is a
    # plain streaming Protocol without that parameter -- construct accordingly.
    # Passing None for a timeout lets sslproto substitute its own defaults
    # (constants.SSL_HANDSHAKE_TIMEOUT / SSL_SHUTDOWN_TIMEOUT) on every
    # supported version. Both variants handle sslcontext=None client-side via
    # _create_transport_context() (and reject it server-side).
    if _PY311:
        return _SSLProtocol(
            loop, app_protocol, sslcontext, waiter,
            server_side, server_hostname,
            ssl_handshake_timeout=ssl_handshake_timeout,
            ssl_shutdown_timeout=ssl_shutdown_timeout)
    # Python 3.10 path (best effort: not locally verifiable on this 3.14
    # dev box, exercised by the CI matrix).
    return _SSLProtocol(
        loop, app_protocol, sslcontext, waiter,
        server_side, server_hostname,
        ssl_handshake_timeout=ssl_handshake_timeout)


cdef object _ssl_app_transport(object ssl_protocol):
    # 3.12+ creates the app-side transport lazily via _get_app_transport();
    # 3.10/3.11 construct it eagerly in __init__.
    get_app = getattr(ssl_protocol, '_get_app_transport', None)
    if get_app is not None:
        return get_app()
    return ssl_protocol._app_transport


cdef inline void _pump_base_exc(Loop loop, object exc):
    # uvloop-style pending-exception pump (same as _timer_dispatch): a
    # KeyboardInterrupt/SystemExit raised by protocol code inside a libhv C
    # callback cannot propagate through the noexcept frame; stash it on the
    # loop and stop the poll so run_forever re-raises it.
    loop._pending_exc = exc
    if loop.hvloop is not NULL:
        hv.hloop_stop(loop.hvloop)


cdef object _make_sock_oserror(int err):
    try:
        msg = os.strerror(err)
    except (ValueError, OverflowError):
        msg = 'unknown error {}'.format(err)
    # OSError with (errno, msg) auto-selects the right subclass
    # (ConnectionResetError, ConnectionRefusedError, TimeoutError, ...).
    return OSError(err, msg)


cdef object _sockaddr_to_pyaddr(hv.sockaddr* sa):
    cdef char ip[72]
    cdef int port = 0
    cdef uint32_t flowinfo = 0
    cdef uint32_t scope_id = 0
    cdef int fam
    ip[0] = 0
    fam = hv.hvloop_sockaddr_info(sa, ip, sizeof(ip), &port,
                                  &flowinfo, &scope_id)
    if fam < 0:
        return None
    ip_str = (<bytes>ip).decode('ascii', 'replace')
    if fam == _AF_INET:
        return (ip_str, port)
    if fam == _AF_INET6:
        return (ip_str, port, flowinfo, scope_id)
    return None


cdef object _dup_socket_view(int fd):
    """Duplicate socket ``fd`` into an independent Python socket object.

    POSIX: plain os.dup -- the new descriptor shares the open file
    description but closing it can never close libhv's fd, and no flag is
    touched.

    Windows (M4 portability): os.dup() only handles CRT fds and libhv fds
    are raw SOCKET handles, so duplicate via socket.socket(fileno=...).dup()
    and detach the temporary wrapper so the original stays owned by libhv.
    CAUTION: socket.dup() copies the temporary wrapper's *Python-level*
    timeout (None == blocking!) onto the duplicate, and the blocking mode
    lives on the underlying socket shared with libhv's handle -- restore
    non-blocking immediately (libhv always operates non-blocking).
    """
    if not _IS_WINDOWS:
        return socket_module.socket(fileno=os.dup(fd))
    tmp = socket_module.socket(fileno=fd)
    try:
        view = tmp.dup()
    finally:
        tmp.detach()
    view.setblocking(False)
    return view


def _set_reuseport(sock):
    if not hasattr(socket_module, 'SO_REUSEPORT'):
        raise ValueError('reuse_port not supported by socket module')
    try:
        sock.setsockopt(socket_module.SOL_SOCKET,
                        socket_module.SO_REUSEPORT, True)
    except OSError:
        raise ValueError('reuse_port not supported by socket module, '
                         'SO_REUSEPORT defined but not implemented.')


# ----- libhv C callbacks ----------------------------------------------------
# Each pair: a ``noexcept nogil`` trampoline handed to libhv plus a GIL-held
# dispatcher whose body is fully wrapped in try/except so no Python exception
# ever escapes back into C (plan section 4.6).

cdef void __tcp_read_cb(hv.hio_t* io, void* buf, int readbytes) noexcept nogil:
    with gil:
        _tcp_dispatch_read(io, buf, readbytes)


cdef void _tcp_dispatch_read(hv.hio_t* io, void* buf, int nread):
    cdef void* ctx = hv.hio_context(io)
    cdef TCPTransport tr
    if ctx is NULL:
        return
    tr = <TCPTransport>ctx
    if tr._hio is NULL or nread <= 0:
        # EOF and read errors never reach this callback: nio_read routes both
        # straight to hio_close, i.e. our close callback (plan section 6).
        return
    try:
        if tr._proto_buffered:
            # BufferedProtocol path (asyncio.protocols.BufferedProtocol;
            # notably the 3.11+ asyncio.sslproto.SSLProtocol): copy the libhv
            # shared readbuf straight into the protocol's own buffer(s).
            tr._deliver_buffered(<char*>buf, <Py_ssize_t>nread)
        else:
            # libhv's readbuf is a loop-level shared buffer that is reused as
            # soon as this callback returns: copy IMMEDIATELY (plan section 6).
            data = PyBytes_FromStringAndSize(<char*>buf, <Py_ssize_t>nread)
            tr._protocol.data_received(data)
    except (KeyboardInterrupt, SystemExit) as exc:
        _pump_base_exc(tr._loop, exc)
    except BaseException as exc:
        tr._loop.call_exception_handler({
            'message': 'Fatal error: protocol data delivery failed.',
            'exception': exc,
            'transport': tr,
            'protocol': tr._protocol,
        })


cdef void __tcp_write_cb(hv.hio_t* io, const void* buf,
                         int writebytes) noexcept nogil:
    with gil:
        _tcp_dispatch_write(io)


cdef void _tcp_dispatch_write(hv.hio_t* io):
    # Fires on every (partial) write completion: drive write_eof completion
    # and the low-water resume_writing side of the flow control protocol.
    # NOTE: also fires synchronously from inside hio_write's direct-write
    # path; in that case _protocol_paused is necessarily False (a paused
    # transport always has a non-empty libhv write queue, which disables the
    # direct-write path), so resume_writing never re-enters protocol.write().
    cdef void* ctx = hv.hio_context(io)
    cdef TCPTransport tr
    cdef size_t size
    if ctx is NULL:
        return
    tr = <TCPTransport>ctx
    if tr._hio is NULL:
        return
    try:
        size = hv.hio_write_bufsize(tr._hio)
        if size == 0 and tr._eof_pending and not tr._eof_written:
            tr._do_write_eof()
        if tr._protocol_paused and size <= tr._low_water:
            tr._protocol_paused = False
            tr._protocol.resume_writing()
    except (KeyboardInterrupt, SystemExit) as exc:
        _pump_base_exc(tr._loop, exc)
    except BaseException as exc:
        tr._loop.call_exception_handler({
            'message': 'protocol.resume_writing() failed',
            'exception': exc,
            'transport': tr,
            'protocol': tr._protocol,
        })


cdef void __tcp_connect_cb(hv.hio_t* io) noexcept nogil:
    with gil:
        _tcp_dispatch_connect(io)


cdef void _tcp_dispatch_connect(hv.hio_t* io):
    cdef void* ctx = hv.hio_context(io)
    cdef TCPTransport tr
    if ctx is NULL:
        return
    tr = <TCPTransport>ctx
    try:
        waiter = tr._waiter
        tr._waiter = None
        if waiter is not None and not waiter.done():
            waiter.set_result(None)
    except (KeyboardInterrupt, SystemExit) as exc:
        _pump_base_exc(tr._loop, exc)
    except BaseException as exc:
        tr._loop.call_exception_handler({
            'message': 'error while completing a TCP connect',
            'exception': exc,
            'transport': tr,
        })


cdef void __tcp_close_cb(hv.hio_t* io) noexcept nogil:
    with gil:
        _tcp_dispatch_close(io)


cdef void _tcp_dispatch_close(hv.hio_t* io):
    # Single funnel for every connection end: peer EOF, errors (incl. failed
    # connects -- nio.c routes them all to hio_close) and our own
    # close()/abort(). May fire from inside the poll OR synchronously from a
    # Python-initiated hio_close. Releases the registration reference taken
    # in TCPTransport.new exactly once; mutually exclusive with
    # Loop.close()'s teardown (which clears the close callback first).
    cdef void* ctx = hv.hio_context(io)
    cdef TCPTransport tr
    cdef int err
    cdef bint was_closing
    if ctx is NULL:
        return
    tr = <TCPTransport>ctx
    if tr._hio is NULL:
        return
    err = hv.hio_error(io)
    was_closing = tr._closing
    hv.hio_set_context(io, NULL)
    tr._hio = NULL
    tr._closing = True
    try:
        tr._loop._hio_objs.discard(tr)
        waiter = tr._waiter
        if waiter is not None:
            # Still connecting: a close here means the connect failed (or was
            # cancelled). No protocol exists yet -- just fail the waiter.
            # libhv detects failed connects via getpeername() and records ITS
            # errno (EINVAL/ENOTCONN); recover the real connect error from
            # SO_ERROR while the fd is still open (nio.c closes it only after
            # this callback returns).
            sock_err = hv.hvloop_sock_error(hv.hio_fd(io))
            if sock_err > 0:
                err = sock_err
            tr._waiter = None
            if not waiter.done():
                if err != 0:
                    waiter.set_exception(_make_sock_oserror(err))
                else:
                    waiter.set_exception(
                        ConnectionError('connection closed before connect '
                                        'completed'))
            return
        if not tr._protocol_connected:
            # Never exposed to a protocol (e.g. torn down mid-handshake or a
            # failed-connect cleanup): nothing to notify.
            return
        if tr._force_close_exc is not None:
            # _force_close(exc) path (asyncio-private transport API used by
            # asyncio.sslproto): deliver the caller-supplied exception.
            exc = tr._force_close_exc
            tr._force_close_exc = None
        elif tr._aborted or err == 0:
            exc = None
        else:
            exc = _make_sock_oserror(err)
        # Peer-initiated clean shutdown: deliver best-effort eof_received()
        # before connection_lost (plan section 6; see _call_connection_lost
        # for the documented half-close deviation).
        got_eof = err == 0 and not was_closing and not tr._aborted
        tr._loop.call_soon(tr._call_connection_lost, exc, got_eof)
    except (KeyboardInterrupt, SystemExit) as exc2:
        _pump_base_exc(tr._loop, exc2)
    except BaseException as exc2:
        tr._loop.call_exception_handler({
            'message': 'error while dispatching transport close',
            'exception': exc2,
            'transport': tr,
        })
    finally:
        Py_DECREF(tr)


cdef void __tcp_accept_cb(hv.hio_t* io) noexcept nogil:
    with gil:
        _tcp_dispatch_accept(io)


cdef void _tcp_dispatch_accept(hv.hio_t* io):
    # ``io`` is the NEW connection's hio. nio_accept copies the listening
    # io's hevent userdata onto it, which is where _TCPListener.new stored
    # the listener backref.
    cdef void* udata = hv.hevent_get_userdata(<void*>io)
    cdef _TCPListener listener
    cdef TCPTransport tr
    cdef Loop loop
    cdef Server server
    # Never leave the borrowed listener pointer on the connection's hio.
    hv.hevent_set_userdata(<void*>io, NULL)
    if udata is NULL:
        hv.hio_close(io)
        return
    listener = <_TCPListener>udata
    server = listener._server
    loop = listener._loop
    if (loop._closed or listener._hio is NULL or server is None or
            server._listeners is None or not server._serving):
        hv.hio_close(io)
        return
    try:
        protocol = server._protocol_factory()
        if server._ssl_context is not None:
            # TLS server (plan section 8): interpose the stdlib SSLProtocol.
            # waiter=None -- handshake failures on the accept path are routed
            # to the loop's exception handler by SSLProtocol._fatal_error
            # (which force-closes the raw transport); the server keeps
            # serving, same as asyncio.
            protocol = _make_ssl_protocol(
                loop, protocol, server._ssl_context, None, True, None,
                server._ssl_handshake_timeout, server._ssl_shutdown_timeout)
        tr = TCPTransport.new(loop, protocol, server, io)
    except (KeyboardInterrupt, SystemExit) as exc:
        _pump_base_exc(loop, exc)
        hv.hio_close(io)
        return
    except BaseException as exc:
        loop.call_exception_handler({
            'message': 'Error in protocol_factory() while accepting a '
                       'new connection',
            'exception': exc,
        })
        hv.hio_close(io)
        return
    server._attach()
    # connection_made (and the read start) run via call_soon so protocol code
    # never executes inside the libhv accept-callback stack (plan section 7).
    loop.call_soon(tr._initialize)


# ----- Server / listener ----------------------------------------------------
@cython.no_gc_clear
cdef class _TCPListener:
    """One listening socket of a Server, wrapping a libhv accept hio.

    fd ownership (plan section 7):
      * self-built sockets (host/port path): the fd was detach()ed from its
        Python socket; libhv owns it and _close() -> hio_close closes it.
      * caller sockets (create_server(sock=...)): the fd belongs to the
        caller's Python socket; _close() only unregisters the hio
        (hvloop_hio_release_external) and never closes the fd.
    """
    cdef:
        Loop _loop
        Server _server
        hv.hio_t* _hio
        int _fd
        object _sock        # caller-owned Python socket, or None
        bint _external
        object _sockview    # lazy dup()-based socket for Server.sockets
        object __weakref__

    @staticmethod
    cdef _TCPListener new(Loop loop, Server server, int fd, object sock):
        cdef _TCPListener self = _TCPListener.__new__(_TCPListener)
        self._loop = loop
        self._server = server
        self._fd = fd
        self._sock = sock
        self._external = sock is not None
        self._sockview = None
        self._hio = hv.hio_get(loop.hvloop, fd)
        if self._hio is NULL:
            raise RuntimeError('hio_get() failed for listen fd {}'.format(fd))
        hv.hio_setcb_accept(self._hio, __tcp_accept_cb)
        hv.hevent_set_userdata(<void*>self._hio, <void*>self)
        # Registration reference (same discipline as TimerHandle): released
        # exactly once, either in _close() or in the loop.close() teardown.
        Py_INCREF(self)
        loop._hio_objs.add(self)
        return self

    cdef _start(self, int backlog):
        if self._hio is NULL:
            raise RuntimeError('server listener is already closed')
        if self._external:
            # asyncio also (re-)listens on caller sockets in start_serving.
            self._sock.listen(backlog)
        if hv.hio_accept(self._hio) != 0:
            raise RuntimeError(
                'hio_accept() failed for listen fd {}'.format(self._fd))

    cdef _close(self):
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._hio = NULL
        self._loop._hio_objs.discard(self)
        if self._external:
            # Unregister from libhv without touching the caller's fd.
            hv.hvloop_hio_release_external(io)
        else:
            hv.hio_setcb_accept(io, <hv.haccept_cb>NULL)
            hv.hevent_set_userdata(<void*>io, NULL)
            # Self-owned fd: hio_close closes it (write queue is empty on a
            # listen socket, so this is immediate).
            hv.hio_close(io)
        if self._sockview is not None:
            try:
                self._sockview.close()
            except OSError:
                pass
            self._sockview = None
        Py_DECREF(self)

    def _loop_close_teardown(self):
        # Called by Loop.close() before hloop_free; _close() already does
        # exactly what is needed (and is mutually exclusive with any later
        # Server.close(), which will see _hio == NULL).
        self._close()

    cdef _get_socket(self):
        if self._external:
            return self._sock
        if self._sockview is None:
            if self._hio is NULL:
                return None
            try:
                # A dup()-based view: an independent descriptor on the same
                # underlying socket, so getsockname/setsockopt work but
                # closing it cannot close libhv's fd.
                self._sockview = _dup_socket_view(self._fd)
            except OSError:
                return None
        return self._sockview


@cython.no_gc_clear
cdef class Server:
    """asyncio-compatible Server returned by loop.create_server (plan §7)."""
    cdef:
        Loop _loop
        object _protocol_factory
        list _listeners        # None once close() was called
        list _waiters          # None once fully closed (wait_closed wakeup)
        int _active_count
        int _backlog
        bint _serving
        object _serving_forever_fut
        object _ssl_context             # ssl.SSLContext, or None (plain TCP)
        object _ssl_handshake_timeout   # float seconds, or None (default)
        object _ssl_shutdown_timeout    # float seconds, or None (default)
        object __weakref__

    @staticmethod
    cdef Server new(Loop loop, object protocol_factory, int backlog,
                    object ssl_context, object ssl_handshake_timeout,
                    object ssl_shutdown_timeout):
        cdef Server self = Server.__new__(Server)
        self._loop = loop
        self._protocol_factory = protocol_factory
        self._listeners = []
        self._waiters = []
        self._active_count = 0
        self._backlog = backlog
        self._serving = False
        self._serving_forever_fut = None
        self._ssl_context = ssl_context
        self._ssl_handshake_timeout = ssl_handshake_timeout
        self._ssl_shutdown_timeout = ssl_shutdown_timeout
        return self

    cdef _add_listener(self, _TCPListener listener):
        self._listeners.append(listener)

    # -- connection accounting (drives wait_closed) -------------------------
    cdef _attach(self):
        self._active_count += 1

    cdef _detach(self):
        self._active_count -= 1
        if self._active_count == 0 and self._listeners is None:
            self._wakeup()

    cdef _wakeup(self):
        waiters = self._waiters
        if waiters is None:
            return
        self._waiters = None
        for waiter in waiters:
            if not waiter.done():
                waiter.set_result(None)

    def _start_serving(self):
        cdef _TCPListener listener
        if self._serving:
            return
        if self._listeners is None:
            raise RuntimeError('server {!r} is closed'.format(self))
        self._serving = True
        for listener in self._listeners:
            listener._start(self._backlog)

    # -- public API ----------------------------------------------------------
    def __repr__(self):
        return '<{} sockets={!r}>'.format(type(self).__name__, self.sockets)

    def get_loop(self):
        return self._loop

    def is_serving(self):
        return self._serving

    @property
    def sockets(self):
        cdef _TCPListener listener
        if self._listeners is None:
            return ()
        result = []
        for listener in self._listeners:
            s = listener._get_socket()
            if s is not None:
                result.append(s)
        return tuple(result)

    def close(self):
        cdef _TCPListener listener
        if self._listeners is None:
            return
        listeners = self._listeners
        self._listeners = None
        for listener in listeners:
            listener._close()
        self._serving = False
        if (self._serving_forever_fut is not None and
                not self._serving_forever_fut.done()):
            self._serving_forever_fut.cancel()
            self._serving_forever_fut = None
        if self._active_count == 0:
            self._wakeup()

    async def start_serving(self):
        self._start_serving()

    async def serve_forever(self):
        if self._serving_forever_fut is not None:
            raise RuntimeError(
                'server {!r} is already being awaited on '
                'serve_forever()'.format(self))
        if self._listeners is None:
            raise RuntimeError('server {!r} is closed'.format(self))
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

    async def wait_closed(self):
        # Returns once close() was called AND all connections created from
        # this server have had connection_lost delivered (_detach).
        if self._waiters is None or (self._listeners is None and
                                     self._active_count == 0):
            return
        waiter = self._loop.create_future()
        self._waiters.append(waiter)
        await waiter

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        self.close()
        await self.wait_closed()


# ----- TCPTransport ----------------------------------------------------------
@cython.no_gc_clear
cdef class TCPTransport:
    """asyncio.Transport implementation over a libhv hio (plan section 6).

    Lifecycle/reference discipline (mirrors TimerHandle): TCPTransport.new
    registers the transport as the hio's context with a Py_INCREF and tracks
    it in loop._hio_objs; the close dispatch and Loop.close() teardown are
    mutually exclusive paths that each null the hio pointer, discard from the
    tracking set and Py_DECREF exactly once. Every public method checks
    _hio == NULL first, so calls after close/teardown are safe no-ops.
    """
    cdef:
        Loop _loop
        hv.hio_t* _hio
        object _protocol
        Server _server          # set for server-side connections, else None
        dict _extra
        object _waiter          # create_connection connect waiter
        object _sock_view       # lazy dup()-based socket for extra_info
        object _force_close_exc # exception passed to _force_close()
        bint _protocol_connected   # connection_made was delivered
        bint _proto_buffered    # protocol is an asyncio.BufferedProtocol
        bint _closing
        bint _paused            # reading paused via pause_reading()
        bint _protocol_paused   # pause_writing() delivered
        bint _eof_pending       # write_eof() called, waiting for drain
        bint _eof_written       # shutdown(SHUT_WR) done
        bint _aborted
        size_t _high_water
        size_t _low_water
        unsigned int _conn_lost
        object __weakref__

    @staticmethod
    cdef TCPTransport new(Loop loop, object protocol, Server server,
                          hv.hio_t* io):
        cdef TCPTransport self = TCPTransport.__new__(TCPTransport)
        self._loop = loop
        self._protocol = protocol
        self._server = server
        self._hio = io
        self._extra = {}
        self._waiter = None
        self._sock_view = None
        self._force_close_exc = None
        self._protocol_connected = False
        self._proto_buffered = False
        self._closing = False
        self._paused = False
        self._protocol_paused = False
        self._eof_pending = False
        self._eof_written = False
        self._aborted = False
        self._high_water = _FLOW_CONTROL_HIGH_WATER
        self._low_water = _FLOW_CONTROL_HIGH_WATER // 4
        self._conn_lost = 0
        hv.hio_set_context(io, <void*>self)
        hv.hio_setcb_read(io, __tcp_read_cb)
        hv.hio_setcb_write(io, __tcp_write_cb)
        hv.hio_setcb_close(io, __tcp_close_cb)
        # Flow control is the protocol's job (pause_writing); never let libhv
        # kill the connection on its internal 16MiB write-buffer cap.
        hv.hio_set_max_write_bufsize(io, 0xffffffff)
        # asyncio enables TCP_NODELAY on TCP transports by default.
        hv.tcp_nodelay(hv.hio_fd(io), 1)
        Py_INCREF(self)
        loop._hio_objs.add(self)
        return self

    def __repr__(self):
        state = []
        if self._hio is NULL:
            state.append('closed')
        elif self._closing:
            state.append('closing')
        else:
            state.append('open')
            state.append('fd={}'.format(hv.hio_fd(self._hio)))
        return '<TCPTransport {}>'.format(' '.join(state))

    # -- initialization ------------------------------------------------------
    def _initialize(self):
        # Runs via call_soon for accepted connections (never inside the libhv
        # accept-callback stack, plan section 7) and directly from the
        # create_connection coroutine for client connections.
        if self._hio is NULL or self._closing:
            return
        self._init_extra()
        self._proto_buffered = isinstance(self._protocol,
                                          aio_BufferedProtocol)
        try:
            self._protocol_connected = True
            self._protocol.connection_made(self)
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            self._loop.call_exception_handler({
                'message': 'protocol.connection_made() failed',
                'exception': exc,
                'transport': self,
                'protocol': self._protocol,
            })
        # connection_made may have closed/aborted the transport.
        if self._hio is NULL or self._closing or self._paused:
            return
        hv.hio_read_start(self._hio)

    cdef _init_extra(self):
        if self._hio is NULL:
            return
        if 'sockname' not in self._extra:
            self._extra['sockname'] = _sockaddr_to_pyaddr(
                hv.hio_localaddr(self._hio))
        if 'peername' not in self._extra:
            self._extra['peername'] = _sockaddr_to_pyaddr(
                hv.hio_peeraddr(self._hio))

    cdef _deliver_buffered(self, char* buf, Py_ssize_t nread):
        # asyncio.BufferedProtocol delivery (M4; used by the 3.11+
        # SSLProtocol): copy the libhv loop-shared readbuf into the buffer(s)
        # the protocol exposes via get_buffer(). The protocol's buffer may be
        # smaller than nread, so loop in chunks; every chunk is fully copied
        # before buffer_updated() runs (which may consume/replace the buffer).
        cdef Py_ssize_t offset = 0
        cdef Py_ssize_t n
        cdef Py_buffer pybuf
        while offset < nread:
            if self._hio is NULL or self._protocol is None:
                # buffer_updated() closed the transport mid-delivery; the
                # remaining ciphertext belongs to a dead connection.
                return
            buf_obj = self._protocol.get_buffer(nread - offset)
            PyObject_GetBuffer(buf_obj, &pybuf, PyBUF_WRITABLE)
            try:
                n = pybuf.len
                if n <= 0:
                    raise RuntimeError(
                        'get_buffer() returned an empty buffer')
                if n > nread - offset:
                    n = nread - offset
                memcpy(pybuf.buf, buf + offset, <size_t>n)
            finally:
                PyBuffer_Release(&pybuf)
            self._protocol.buffer_updated(n)
            offset += n

    cdef _teardown_failed_connect(self):
        # Close a never-exposed (still-connecting) transport. There is no
        # protocol yet, so the close dispatch only cleans up bookkeeping.
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._closing = True
        # Force the immediate-close path even if libhv buffered something.
        hv.hvloop_hio_set_error(io, _ECONNABORTED)
        hv.hio_close(io)

    # -- extra info ------------------------------------------------------------
    def get_extra_info(self, name, default=None):
        if name == 'socket':
            # Decision (plan section 6): expose a dup()-based socket.socket.
            # It is a real socket object (uvicorn et al. call getsockname /
            # setsockopt on it) on an independent descriptor, so user code
            # closing or leaking it can never close the fd libhv owns. It is
            # cached and closed together with the transport.
            if self._sock_view is None:
                if self._hio is NULL:
                    return default
                try:
                    self._sock_view = _dup_socket_view(hv.hio_fd(self._hio))
                except OSError:
                    return default
            return self._sock_view
        if name in self._extra:
            return self._extra[name]
        if self._hio is not NULL and name in ('sockname', 'peername'):
            self._init_extra()
            return self._extra.get(name, default)
        return default

    # -- protocol / state ------------------------------------------------------
    def set_protocol(self, protocol):
        self._protocol = protocol
        self._proto_buffered = isinstance(protocol, aio_BufferedProtocol)

    def get_protocol(self):
        return self._protocol

    def is_closing(self):
        return self._closing or self._hio is NULL

    # -- reading (plan section 6: hio_read_stop / hio_read_start) --------------
    def is_reading(self):
        return (self._hio is not NULL and not self._closing and
                not self._paused and self._protocol_connected)

    def pause_reading(self):
        # asyncio semantics: idempotent, no-op while closing/closed.
        if self._closing or self._hio is NULL or self._paused:
            return
        self._paused = True
        hv.hio_read_stop(self._hio)

    def resume_reading(self):
        if self._closing or self._hio is NULL or not self._paused:
            return
        self._paused = False
        hv.hio_read_start(self._hio)

    # -- writing ----------------------------------------------------------------
    def write(self, object data):
        cdef int rc
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError(
                'data argument must be a bytes-like object, not '
                '{!r}'.format(type(data).__name__))
        if self._eof_pending or self._eof_written:
            raise RuntimeError('Cannot call write() after write_eof()')
        if len(data) == 0:
            return
        if self._closing or self._hio is NULL:
            # Same accounting/warning behaviour as asyncio's selector
            # transport for writes after the connection was lost.
            if self._conn_lost >= <unsigned int>_LOG_THRESHOLD_FOR_CONNLOST_WRITES:
                aio_logger.warning('socket.send() raised exception.')
            self._conn_lost += 1
            return
        if not isinstance(data, bytes):
            data = bytes(data)
        # hio_write either sends immediately or memcpy's the remainder into
        # its own write queue before returning, so a temporary is fine.
        rc = hv.hio_write(self._hio, <const void*>PyBytes_AS_STRING(data),
                          <size_t>PyBytes_GET_SIZE(data))
        if rc < 0:
            # The connection broke; libhv has scheduled the close path, which
            # delivers connection_lost with hio_error.
            return
        self._maybe_pause_protocol()

    def writelines(self, list_of_data):
        self.write(b''.join(list_of_data))

    cdef _maybe_pause_protocol(self):
        if self._hio is NULL or self._protocol_paused:
            return
        if hv.hio_write_bufsize(self._hio) <= self._high_water:
            return
        self._protocol_paused = True
        try:
            self._protocol.pause_writing()
        except (KeyboardInterrupt, SystemExit):
            raise
        except BaseException as exc:
            self._loop.call_exception_handler({
                'message': 'protocol.pause_writing() failed',
                'exception': exc,
                'transport': self,
                'protocol': self._protocol,
            })

    def get_write_buffer_size(self):
        if self._hio is NULL:
            return 0
        return hv.hio_write_bufsize(self._hio)

    def get_write_buffer_limits(self):
        return (self._low_water, self._high_water)

    def set_write_buffer_limits(self, high=None, low=None):
        if high is None:
            if low is None:
                high = _FLOW_CONTROL_HIGH_WATER
            else:
                high = 4 * low
        if low is None:
            low = high // 4
        if not high >= low >= 0:
            raise ValueError(
                'high ({!r}) must be >= low ({!r}) must be >= 0'.format(
                    high, low))
        self._high_water = high
        self._low_water = low
        self._maybe_pause_protocol()

    # -- EOF / closing ------------------------------------------------------------
    def can_write_eof(self):
        return True

    def write_eof(self):
        # Plan section 6: libhv has no half-close API; shutdown(SHUT_WR) on
        # the raw fd once the libhv write buffer has drained.
        if self._eof_pending or self._eof_written:
            return
        if self._closing or self._hio is NULL:
            return
        self._eof_pending = True
        if hv.hio_write_bufsize(self._hio) == 0:
            self._do_write_eof()

    cdef _do_write_eof(self):
        self._eof_written = True
        if self._hio is not NULL:
            hv.hvloop_shutdown_wr(hv.hio_fd(self._hio))

    def close(self):
        # Graceful close: stop reading; libhv's hio_close itself defers the
        # actual close until the write queue is flushed (nio.c), then fires
        # the close callback -> connection_lost(None).
        if self._closing or self._hio is NULL:
            return
        self._closing = True
        hv.hio_read_stop(self._hio)
        hv.hio_close(self._hio)

    def abort(self):
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._aborted = True
        self._closing = True
        # hio_close defers while the write queue is non-empty and error == 0;
        # setting an error forces the immediate-close path (buffer discarded).
        hv.hvloop_hio_set_error(io, _ECONNABORTED)
        hv.hio_close(io)

    def _force_close(self, exc):
        # asyncio-private transport API (called by asyncio.sslproto's
        # _fatal_error, and by asyncio internals generally): close
        # immediately, discarding buffered writes, and deliver ``exc`` to
        # protocol.connection_lost.
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._force_close_exc = exc
        self._aborted = True     # suppress eof_received / hio_error mapping
        self._closing = True
        hv.hvloop_hio_set_error(io, _ECONNABORTED)
        hv.hio_close(io)

    def _call_connection_lost(self, exc, eof):
        # Scheduled via call_soon by the close dispatch, so protocol code runs
        # outside the libhv callback stack and KI/SE propagate through
        # Handle._run naturally.
        protocol = self._protocol
        if protocol is None:
            return
        try:
            if eof:
                try:
                    protocol.eof_received()
                    # Documented deviation (plan section 6): libhv closes the
                    # connection as soon as it sees EOF, so returning True
                    # from eof_received() cannot keep the transport open for
                    # writing; connection_lost always follows.
                except (KeyboardInterrupt, SystemExit):
                    raise
                except BaseException as eof_exc:
                    self._loop.call_exception_handler({
                        'message': 'protocol.eof_received() failed',
                        'exception': eof_exc,
                        'transport': self,
                        'protocol': protocol,
                    })
            protocol.connection_lost(exc)
        finally:
            self._protocol = None
            server = self._server
            self._server = None
            if server is not None:
                server._detach()
            if self._sock_view is not None:
                try:
                    self._sock_view.close()
                except OSError:
                    pass
                self._sock_view = None

    def _loop_close_teardown(self):
        # Called by Loop.close() right before hloop_free: detach this wrapper
        # from the C structures so nothing re-enters Python while libhv frees
        # (and, for our self-owned fds, closes) the ios. Mutually exclusive
        # with the close dispatch: the loop is not running and we clear the
        # close callback before hloop_free can invoke it.
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._hio = NULL
        self._closing = True
        hv.hio_setcb_read(io, <hv.hread_cb>NULL)
        hv.hio_setcb_write(io, <hv.hwrite_cb>NULL)
        hv.hio_setcb_close(io, <hv.hclose_cb>NULL)
        hv.hio_setcb_connect(io, <hv.hconnect_cb>NULL)
        hv.hio_set_context(io, NULL)
        waiter = self._waiter
        self._waiter = None
        if waiter is not None and not waiter.done():
            waiter.cancel()
        if self._sock_view is not None:
            try:
                self._sock_view.close()
            except OSError:
                pass
            self._sock_view = None
        self._protocol = None
        self._server = None
        Py_DECREF(self)


# ===========================================================================
# fd watching & Unix signal support (M2b, plan sections 5 & 9)
# ===========================================================================

def _sighandler_noop(signum, frame):
    """Python-level no-op signal handler installed by add_signal_handler().

    The real work happens in CPython's C-level handler, which writes the
    signal number to the wakeup fd (signal.set_wakeup_fd); this stub merely
    keeps a C-level handler installed (SIG_DFL/SIG_IGN would bypass the
    wakeup-fd write entirely).
    """
    pass


cdef int _fileobj_to_fd(object fileobj) except -1:
    # asyncio/selectors semantics: an int fd, or any object with fileno().
    cdef int fd
    if isinstance(fileobj, int):
        fd = fileobj
    else:
        try:
            fd = int(fileobj.fileno())
        except (AttributeError, TypeError, ValueError):
            raise ValueError(
                'Invalid file object: {!r}'.format(fileobj)) from None
    if fd < 0:
        raise ValueError('Invalid file descriptor: {}'.format(fd))
    return fd


cdef void __fd_watcher_cb(hv.hio_t* io) noexcept nogil:
    # Installed via hio_add as the io's raw event-dispatch callback, REPLACING
    # nio.c's hio_handle_events (hloop.c: io->cb = cb): libhv therefore never
    # reads/writes the fd itself for watched fds.
    with gil:
        _fd_watcher_dispatch(io)


cdef void _fd_watcher_dispatch(hv.hio_t* io):
    cdef int revents = hv.hio_revents(io)
    cdef void* ctx = hv.hio_context(io)
    cdef _FDWatcher w
    # Mirror the tail of nio.c's hio_handle_events: the iowatcher backends
    # accumulate readiness with |= into io->revents, so it must be cleared
    # after every dispatch or a stale HV_READ/HV_WRITE bit would mis-dispatch
    # the wrong direction on this io's next wakeup.
    hv.hvloop_io_clear_revents(io)
    if ctx is NULL:
        return
    w = <_FDWatcher>ctx
    if w._hio is not io:
        return
    try:
        if (revents & hv.HV_READ) and w._reader is not None:
            # Handle._run routes ordinary exceptions to the loop's exception
            # handler itself; only KeyboardInterrupt/SystemExit re-raise.
            w._reader._run()
        # The reader callback may have removed the writer or torn the whole
        # watcher down (w._hio nulled): re-check before the writer dispatch.
        if (w._hio is io and (revents & hv.HV_WRITE) and
                w._writer is not None):
            w._writer._run()
    except (KeyboardInterrupt, SystemExit) as exc:
        _pump_base_exc(w._loop, exc)


@cython.no_gc_clear
cdef class _FDWatcher:
    """Raw readiness watcher for one caller-owned fd (add_reader/add_writer).

    Design (M2b): hio_get(loop, fd) + hio_add(io, __fd_watcher_cb, events).
    hio_add REPLACES the io's event-dispatch callback, so libhv's nio layer
    never touches the fd; __fd_watcher_cb translates hio_revents() into the
    reader/writer Handles and clears revents, exactly like the tail of
    hio_handle_events. The poll backends are level-triggered, so a writer
    keeps firing while the fd stays writable and a reader while data is
    pending (asyncio semantics).

    fd ownership: always the caller's. Teardown (last remove_* or
    loop.close()) unregisters via hvloop_hio_release_external, which never
    closes the fd -- the fd must remain valid and usable afterwards.

    Reference discipline (mirrors TimerHandle/_TCPListener): Py_INCREF at
    registration plus loop._hio_objs/_fd_watchers tracking; _teardown() is
    the single release point (guarded by _hio == NULL), reachable from
    _remove() and from Loop.close().

    Constraints (documented, not enforced): a watched fd must not
    simultaneously be owned by a transport/listener of the same loop (both
    would fight over io->cb), and libhv's high-level hio_read/hio_write API
    must not be used on a watched io. libhv also flips watched socket fds to
    non-blocking mode (hio_ready -> hio_socket_init).
    """

    cdef:
        Loop _loop
        hv.hio_t* _hio
        int _fd
        Handle _reader          # persistent (_repeat) Handle, or None
        Handle _writer          # persistent (_repeat) Handle, or None
        object __weakref__

    @staticmethod
    cdef _FDWatcher new(Loop loop, int fd):
        cdef _FDWatcher self = _FDWatcher.__new__(_FDWatcher)
        self._loop = loop
        self._fd = fd
        self._reader = None
        self._writer = None
        self._hio = hv.hio_get(loop.hvloop, fd)
        if self._hio is NULL:
            raise RuntimeError('hio_get() failed for fd {}'.format(fd))
        hv.hio_set_context(self._hio, <void*>self)
        # Registration reference (same discipline as TimerHandle): released
        # exactly once in _teardown().
        Py_INCREF(self)
        loop._hio_objs.add(self)
        loop._fd_watchers[fd] = self
        return self

    def __repr__(self):
        return '<_FDWatcher fd={} reader={} writer={}>'.format(
            self._fd, self._reader is not None, self._writer is not None)

    cdef _add(self, int events, object callback, tuple args):
        # events is exactly HV_READ or HV_WRITE (enforced by the callers).
        cdef Handle handle
        cdef Handle old
        if self._hio is NULL:
            raise RuntimeError(
                'fd watcher for fd {} is already closed'.format(self._fd))
        if hv.hio_add(self._hio, __fd_watcher_cb, events) != 0:
            raise OSError(
                'hio_add() failed for fd {} (events={})'.format(
                    self._fd, events))
        handle = Handle(callback, args, self._loop, None)
        handle._repeat = True   # runs once per readiness event, not consumed
        if events == hv.HV_READ:
            old = self._reader
            self._reader = handle
        else:
            old = self._writer
            self._writer = handle
        if old is not None:
            # add_reader/add_writer on an already-watched direction replaces
            # the previous callback (asyncio semantics).
            old.cancel()

    cdef bint _remove(self, int events):
        cdef Handle old
        if events == hv.HV_READ:
            old = self._reader
            self._reader = None
        else:
            old = self._writer
            self._writer = None
        if old is None:
            return False
        old.cancel()
        if self._hio is not NULL:
            if self._reader is None and self._writer is None:
                # Last direction removed: fully unregister (this also
                # deregisters both events) without closing the caller's fd.
                self._teardown()
            else:
                hv.hio_del(self._hio, events)
        return True

    cdef _teardown(self):
        cdef hv.hio_t* io = self._hio
        if io is NULL:
            return
        self._hio = NULL
        self._loop._hio_objs.discard(self)
        self._loop._fd_watchers.pop(self._fd, None)
        if self._reader is not None:
            self._reader.cancel()
            self._reader = None
        if self._writer is not None:
            self._writer.cancel()
            self._writer = None
        # Caller-owned fd: unregister from libhv WITHOUT closing it (the
        # io_type is reset so hio_close skips closesocket; the context and
        # all C callbacks are cleared so nothing re-enters Python -- see
        # hvloop_shim.h). Safe both mid-dispatch (a callback removing its own
        # watcher) and from Loop.close().
        hv.hvloop_hio_release_external(io)
        Py_DECREF(self)

    def _loop_close_teardown(self):
        # Called by Loop.close() before hloop_free; the caller's fd stays
        # open and usable afterwards (M2b requirement).
        self._teardown()
