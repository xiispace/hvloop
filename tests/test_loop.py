"""M1 unit tests for the hvloop Loop core (plan section 12.1).

Covers: call_soon FIFO ordering, call_later/call_at precision and
cancellation, call_soon_threadsafe cross-thread wakeup latency, stop/close
semantics, exception handler, run_until_complete exception propagation,
shutdown_asyncgens, and loop.time() monotonicity.

These are synchronous tests that construct and drive an hvloop Loop directly.
"""

import asyncio
import importlib.util
import sys
import threading
import time

import pytest

import hvloop


# ---------------------------------------------------------------------------
# Construction / lifecycle
# ---------------------------------------------------------------------------
def test_new_event_loop_type():
    loop = hvloop.new_event_loop()
    try:
        assert isinstance(loop, hvloop.Loop)
        assert isinstance(loop, asyncio.AbstractEventLoop)
        assert not loop.is_running()
        assert not loop.is_closed()
        assert "running=False" in repr(loop)
    finally:
        loop.close()


def test_close_is_idempotent(loop):
    assert not loop.is_closed()
    loop.close()
    assert loop.is_closed()
    loop.close()  # second close is a no-op
    assert loop.is_closed()


def test_close_while_running_raises(loop):
    def try_close():
        with pytest.raises(RuntimeError):
            loop.close()
        loop.stop()

    loop.call_soon(try_close)
    loop.run_forever()


def test_call_after_close_raises(loop):
    loop.close()
    with pytest.raises(RuntimeError):
        loop.call_soon(lambda: None)
    with pytest.raises(RuntimeError):
        loop.call_later(0, lambda: None)


def test_context_manager_closes():
    with hvloop.new_event_loop() as loop:
        assert not loop.is_closed()
    assert loop.is_closed()


# ---------------------------------------------------------------------------
# call_soon ordering
# ---------------------------------------------------------------------------
def test_call_soon_fifo_order(loop):
    order = []
    for i in range(20):
        loop.call_soon(order.append, i)
    loop.call_soon(loop.stop)
    loop.run_forever()
    assert order == list(range(20))


def test_call_soon_scheduled_during_turn_runs_next_turn(loop):
    # A callback scheduled while running the current ready snapshot must not
    # starve the loop; it runs on a later turn (plan section 4).
    seen = []

    def first():
        seen.append("first")
        loop.call_soon(second)

    def second():
        seen.append("second")
        loop.stop()

    loop.call_soon(first)
    loop.run_forever()
    assert seen == ["first", "second"]


def test_call_soon_returns_cancellable_handle(loop):
    calls = []
    h = loop.call_soon(calls.append, "x")
    assert not h.cancelled()
    h.cancel()
    assert h.cancelled()
    loop.call_soon(loop.stop)
    loop.run_forever()
    assert calls == []


# ---------------------------------------------------------------------------
# Timers: call_later / call_at precision and cancellation
# ---------------------------------------------------------------------------
def test_call_later_precision(loop):
    results = []
    start = loop.time()

    def cb():
        results.append(loop.time() - start)
        loop.stop()

    loop.call_later(0.1, cb)
    loop.run_forever()
    assert len(results) == 1
    # Allow generous upper bound for CI jitter, but ensure it actually waited.
    assert 0.08 <= results[0] <= 0.4, results[0]


def test_call_later_ordering(loop):
    order = []
    loop.call_later(0.06, lambda: order.append("c"))
    loop.call_later(0.02, lambda: order.append("a"))
    loop.call_later(0.04, lambda: order.append("b"))
    loop.call_later(0.08, loop.stop)
    loop.run_forever()
    assert order == ["a", "b", "c"]


def test_call_later_negative_runs_soon(loop):
    order = []
    loop.call_later(-1, lambda: order.append("late"))
    loop.call_soon(lambda: order.append("soon"))
    loop.call_later(0.02, loop.stop)
    loop.run_forever()
    # Both should run; negative delay must still fire.
    assert "late" in order and "soon" in order


def test_call_at_uses_loop_clock(loop):
    results = []
    when = loop.time() + 0.05

    def cb():
        results.append(loop.time())
        loop.stop()

    handle = loop.call_at(when, cb)
    assert abs(handle.when() - when) < 1e-6
    loop.run_forever()
    assert results[0] >= when - 0.01


def test_timer_cancel_prevents_callback(loop):
    fired = []
    h = loop.call_later(0.02, lambda: fired.append(1))
    h.cancel()
    assert h.cancelled()
    loop.call_later(0.06, loop.stop)
    loop.run_forever()
    assert fired == []


def test_timer_cancel_is_idempotent(loop):
    h = loop.call_later(10, lambda: None)
    h.cancel()
    h.cancel()
    assert h.cancelled()
    loop.call_soon(loop.stop)
    loop.run_forever()


def test_many_timers(loop):
    fired = []
    n = 50
    for i in range(n):
        loop.call_later(0.001 * (i % 5), lambda i=i: fired.append(i))
    loop.call_later(0.1, loop.stop)
    loop.run_forever()
    assert len(fired) == n


# ---------------------------------------------------------------------------
# loop.time() monotonicity
# ---------------------------------------------------------------------------
def test_time_is_monotonic(loop):
    samples = [loop.time() for _ in range(1000)]
    for a, b in zip(samples, samples[1:]):
        assert b >= a


def test_time_advances(loop):
    t0 = loop.time()
    time.sleep(0.02)
    t1 = loop.time()
    assert t1 > t0


# ---------------------------------------------------------------------------
# call_soon_threadsafe cross-thread wakeup
# ---------------------------------------------------------------------------
def test_call_soon_threadsafe_wakeup_latency(loop):
    # The loop is blocked in an (effectively infinite) poll with no timers.
    # A threadsafe schedule must wake it well under libhv's 100ms block cap;
    # we assert < 50ms to prove the wakeup eventfd path works.
    latency = {}

    def worker():
        time.sleep(0.05)  # ensure the loop is parked in poll
        posted = time.monotonic()

        def cb():
            latency["value"] = time.monotonic() - posted
            loop.stop()

        loop.call_soon_threadsafe(cb)

    t = threading.Thread(target=worker)
    t.start()
    loop.run_forever()
    t.join()

    assert "value" in latency
    assert latency["value"] < 0.05, latency["value"]


def test_call_soon_threadsafe_multiple(loop):
    received = []

    def worker():
        time.sleep(0.02)
        for i in range(10):
            loop.call_soon_threadsafe(received.append, i)
        loop.call_soon_threadsafe(loop.stop)

    t = threading.Thread(target=worker)
    t.start()
    loop.run_forever()
    t.join()
    assert received == list(range(10))


def test_stop_from_another_thread(loop):
    started = threading.Event()

    def keepalive():
        # A repeating-ish chain so the loop stays busy until stopped.
        if loop.is_running():
            loop.call_later(0.01, keepalive)

    def worker():
        started.wait(1.0)
        time.sleep(0.05)
        loop.call_soon_threadsafe(loop.stop)

    loop.call_soon(started.set)
    loop.call_soon(keepalive)
    t = threading.Thread(target=worker)
    t.start()
    loop.run_forever()
    t.join()
    assert not loop.is_running()


# ---------------------------------------------------------------------------
# stop semantics
# ---------------------------------------------------------------------------
def test_stop_before_run_runs_one_batch(loop):
    # asyncio semantics: stop() before/at start lets the current ready batch
    # run, then exits. We schedule stop first, then a callback; both queued
    # callbacks in the first snapshot run.
    ran = []
    loop.call_soon(loop.stop)
    loop.call_soon(lambda: ran.append(1))
    loop.run_forever()
    assert ran == [1]
    assert not loop.is_running()


def test_run_forever_can_restart(loop):
    counter = []
    loop.call_soon(lambda: (counter.append(1), loop.stop()))
    loop.run_forever()
    loop.call_soon(lambda: (counter.append(2), loop.stop()))
    loop.run_forever()
    assert counter == [1, 2]


def test_run_forever_while_running_raises(loop):
    def reenter():
        with pytest.raises(RuntimeError):
            loop.run_forever()
        loop.stop()

    loop.call_soon(reenter)
    loop.run_forever()


# ---------------------------------------------------------------------------
# Exception handler
# ---------------------------------------------------------------------------
def test_default_exception_handler_get_set(loop):
    assert loop.get_exception_handler() is None

    def handler(lp, ctx):
        pass

    loop.set_exception_handler(handler)
    assert loop.get_exception_handler() is handler
    loop.set_exception_handler(None)
    assert loop.get_exception_handler() is None


def test_set_exception_handler_validates(loop):
    with pytest.raises(TypeError):
        loop.set_exception_handler(123)


def test_callback_exception_goes_to_handler(loop):
    caught = []
    loop.set_exception_handler(lambda lp, ctx: caught.append(ctx))

    def boom():
        raise ValueError("boom")

    loop.call_soon(boom)
    loop.call_soon(loop.stop)
    loop.run_forever()
    assert len(caught) == 1
    assert isinstance(caught[0]["exception"], ValueError)
    assert "message" in caught[0]


def test_timer_callback_exception_goes_to_handler(loop):
    caught = []
    loop.set_exception_handler(lambda lp, ctx: caught.append(ctx))

    def boom():
        raise RuntimeError("timer-boom")

    loop.call_later(0.01, boom)
    loop.call_later(0.05, loop.stop)
    loop.run_forever()
    assert len(caught) == 1
    assert isinstance(caught[0]["exception"], RuntimeError)


def test_call_exception_handler_direct(loop):
    caught = []
    loop.set_exception_handler(lambda lp, ctx: caught.append(ctx))
    loop.call_exception_handler({"message": "manual"})
    assert caught == [{"message": "manual"}]


# ---------------------------------------------------------------------------
# run_until_complete + exception propagation
# ---------------------------------------------------------------------------
def test_run_until_complete_returns_result(loop):
    async def coro():
        await asyncio.sleep(0)
        return 42

    assert loop.run_until_complete(coro()) == 42


def test_run_until_complete_propagates_exception(loop):
    async def coro():
        await asyncio.sleep(0)
        raise ValueError("propagated")

    with pytest.raises(ValueError, match="propagated"):
        loop.run_until_complete(coro())


def test_run_until_complete_with_future(loop):
    fut = loop.create_future()
    loop.call_later(0.01, fut.set_result, "done")
    assert loop.run_until_complete(fut) == "done"


def test_run_until_complete_nested_error(loop):
    async def inner():
        raise KeyError("inner")

    async def outer():
        return await inner()

    with pytest.raises(KeyError, match="inner"):
        loop.run_until_complete(outer())


# ---------------------------------------------------------------------------
# Futures / tasks
# ---------------------------------------------------------------------------
def test_create_future(loop):
    fut = loop.create_future()
    assert isinstance(fut, asyncio.Future)
    assert fut.get_loop() is loop


def test_create_task_and_name(loop):
    async def coro():
        return "ok"

    async def driver():
        task = loop.create_task(coro(), name="my-task")
        assert task.get_name() == "my-task"
        return await task

    assert loop.run_until_complete(driver()) == "ok"


@pytest.mark.skipif(
    sys.version_info < (3, 11),
    reason="loop.create_task(context=...) was added to asyncio in 3.11",
)
def test_create_task_with_context(loop):
    import contextvars

    var = contextvars.ContextVar("var", default="default")

    async def coro():
        return var.get()

    async def driver():
        ctx = contextvars.copy_context()
        ctx.run(var.set, "ctxval")
        task = loop.create_task(coro(), context=ctx)
        return await task

    assert loop.run_until_complete(driver()) == "ctxval"


def test_task_factory_get_set(loop):
    assert loop.get_task_factory() is None

    def factory(lp, coro, **kw):
        return asyncio.Task(coro, loop=lp, **kw)

    loop.set_task_factory(factory)
    assert loop.get_task_factory() is factory

    async def coro():
        return "factory-ok"

    async def driver():
        return await loop.create_task(coro())

    assert loop.run_until_complete(driver()) == "factory-ok"
    loop.set_task_factory(None)


def test_set_task_factory_validates(loop):
    with pytest.raises(TypeError):
        loop.set_task_factory(123)


# ---------------------------------------------------------------------------
# Debug flag
# ---------------------------------------------------------------------------
def test_debug_flag(loop):
    loop.set_debug(True)
    assert loop.get_debug() is True
    loop.set_debug(False)
    assert loop.get_debug() is False


def test_debug_mode_rejects_coroutine_in_call_soon(loop):
    loop.set_debug(True)

    async def coro():
        pass

    c = coro()
    try:
        with pytest.raises(TypeError):
            loop.call_soon(c)
    finally:
        c.close()


# ---------------------------------------------------------------------------
# Executor / DNS
# ---------------------------------------------------------------------------
def test_run_in_executor(loop):
    async def driver():
        return await loop.run_in_executor(None, lambda: 1 + 1)

    assert loop.run_until_complete(driver()) == 2


def test_set_default_executor_validates(loop):
    with pytest.raises(TypeError):
        loop.set_default_executor(object())


def test_getaddrinfo_localhost(loop):
    async def driver():
        import socket

        return await loop.getaddrinfo(
            "127.0.0.1", 80, family=socket.AF_INET, type=socket.SOCK_STREAM
        )

    infos = loop.run_until_complete(driver())
    assert any(info[4][0] == "127.0.0.1" for info in infos)


def test_getnameinfo(loop):
    import socket

    async def driver():
        # NI_NUMERICHOST keeps the result stable regardless of /etc/hosts.
        return await loop.getnameinfo(("127.0.0.1", 80), socket.NI_NUMERICHOST)

    host, service = loop.run_until_complete(driver())
    assert host == "127.0.0.1"


# ---------------------------------------------------------------------------
# shutdown_asyncgens
# ---------------------------------------------------------------------------
def test_shutdown_asyncgens(loop):
    finalized = []

    async def gen():
        try:
            while True:
                yield 1
        finally:
            finalized.append(True)

    async def driver():
        g = gen()
        assert await g.__anext__() == 1
        # Drop the only reference *and* explicitly shut down async gens.
        await loop.shutdown_asyncgens()

    # Keep a live reference so finalization happens via shutdown, not GC.
    holder = {}

    async def driver2():
        holder["g"] = gen()
        assert await holder["g"].__anext__() == 1
        await loop.shutdown_asyncgens()

    loop.run_until_complete(driver2())
    assert finalized == [True]


def test_shutdown_asyncgens_empty(loop):
    async def driver():
        await loop.shutdown_asyncgens()

    loop.run_until_complete(driver())  # should not raise


# ---------------------------------------------------------------------------
# asyncio infra hooks
# ---------------------------------------------------------------------------
def test_timer_handle_cancelled_hook(loop):
    # Used by asyncio internals; must be callable and a no-op.
    h = loop.call_later(10, lambda: None)
    loop._timer_handle_cancelled(h)
    h.cancel()
    loop.call_soon(loop.stop)
    loop.run_forever()


def test_shutdown_default_executor(loop):
    async def driver():
        await loop.run_in_executor(None, lambda: 1)
        await loop.shutdown_default_executor()

    loop.run_until_complete(driver())


# ---------------------------------------------------------------------------
# Regression: close() teardown of un-fired htimers (M1 acceptance fix #1)
# ---------------------------------------------------------------------------
def test_cancel_after_close_does_not_crash():
    # Before the fix, close() freed the htimer_t via hloop_free without clearing
    # our TimerHandle; a subsequent handle.cancel() then called htimer_del on
    # freed memory (use-after-free). Now close() nulls the handle's timer first.
    lp = hvloop.new_event_loop()
    h = lp.call_later(100, lambda: None)
    lp.close()
    # These must be safe no-ops, not a crash.
    h.cancel()
    h.cancel()
    assert h.cancelled()


def test_unfired_timers_collected_after_close():
    # Each registered htimer Py_INCREF'd its TimerHandle. Without close()
    # teardown those references (and the callbacks/args they pin) leaked. Verify
    # the handles are reclaimable once the loop is closed.
    import gc
    import weakref

    lp = hvloop.new_event_loop()
    refs = [weakref.ref(lp.call_later(100, lambda: None)) for _ in range(200)]
    # We intentionally keep no strong refs to the handles themselves.
    assert sum(1 for r in refs if r() is not None) == 200
    lp.close()
    gc.collect()
    assert sum(1 for r in refs if r() is not None) == 0


def test_close_does_not_leak_callback_objects():
    # The callback (and its closed-over args) must not be kept alive by a
    # leaked registration reference after close().
    import gc
    import weakref

    class Sentinel:
        pass

    lp = hvloop.new_event_loop()
    sentinel = Sentinel()
    ref = weakref.ref(sentinel)
    lp.call_later(100, lambda s=sentinel: None)
    del sentinel
    lp.close()
    gc.collect()
    assert ref() is None


# ---------------------------------------------------------------------------
# Regression: KeyboardInterrupt / SystemExit from a timer callback must
# propagate out of run_forever()/run_until_complete() (M1 acceptance fix #2)
# ---------------------------------------------------------------------------
def test_timer_callback_keyboardinterrupt_propagates(loop, capfd):
    def boom():
        raise KeyboardInterrupt

    loop.call_later(0.01, boom)
    # A long sleep so the loop would otherwise stay parked in poll.
    fut = loop.create_future()
    loop.call_later(5.0, fut.cancel)

    with pytest.raises(KeyboardInterrupt):
        loop.run_forever()

    # No "Exception ignored in: ... _on_timer" stderr noise.
    err = capfd.readouterr().err
    assert "Exception ignored" not in err, err


def test_timer_callback_systemexit_propagates(loop, capfd):
    def boom():
        raise SystemExit(7)

    loop.call_later(0.01, boom)
    loop.call_later(5.0, loop.stop)

    with pytest.raises(SystemExit) as ei:
        loop.run_forever()
    assert ei.value.code == 7

    err = capfd.readouterr().err
    assert "Exception ignored" not in err, err


def test_timer_callback_ki_propagates_via_run_until_complete(loop, capfd):
    async def main():
        loop.call_later(0.01, _raise_ki)
        await asyncio.sleep(10)

    def _raise_ki():
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        loop.run_until_complete(main())

    err = capfd.readouterr().err
    assert "Exception ignored" not in err, err


def test_timer_callback_plain_exception_still_goes_to_handler(loop):
    # Fix #2 must not change behavior for ordinary exceptions: they keep going
    # to call_exception_handler and the loop keeps running.
    caught = []
    loop.set_exception_handler(lambda lp, ctx: caught.append(ctx))
    loop.call_later(0.01, lambda: (_ for _ in ()).throw(ValueError("x")))
    loop.call_later(0.05, loop.stop)
    loop.run_forever()  # must NOT raise
    assert len(caught) == 1
    assert isinstance(caught[0]["exception"], ValueError)


# ---------------------------------------------------------------------------
# Regression: timer precision rounds UP, never fires before `when`
# (M1 acceptance fix #3)
# ---------------------------------------------------------------------------
def test_timer_never_fires_before_when(loop):
    # 10.4ms with nearest-rounding used to truncate to 10ms and could fire
    # ~0.4ms early. ceil() must guarantee the callback runs at or after `when`.
    results = []
    when = loop.time() + 0.0104

    def cb():
        results.append(loop.time())
        loop.stop()

    loop.call_at(when, cb)
    loop.run_forever()
    assert len(results) == 1
    assert results[0] >= when, (results[0], when, results[0] - when)


def test_timer_precision_repeated_no_early_fire():
    # Run several fresh loops to shake out rounding-direction regressions.
    for _ in range(30):
        lp = hvloop.new_event_loop()
        try:
            when = lp.time() + 0.0107
            got = {}

            def cb():
                got["t"] = lp.time()
                lp.stop()

            lp.call_at(when, cb)
            lp.run_forever()
            assert got["t"] >= when, (got["t"], when)
        finally:
            lp.close()


# ---------------------------------------------------------------------------
# Regression: time() after close() does not jump back to 0.0 (fix #4)
# ---------------------------------------------------------------------------
def test_time_after_close_does_not_regress():
    lp = hvloop.new_event_loop()
    before = lp.time()
    assert before > 0.0
    lp.close()
    after = lp.time()
    # Must not collapse to 0.0; stays at the value snapshotted at close().
    assert after >= before
    assert after > 0.0


# ---------------------------------------------------------------------------
# Regression: idle loop must not busy-spin at 100% CPU.
#
# hvloop self-drives via hloop_process_events. libhv leaves a freshly created
# loop at HLOOP_STATUS_STOP (only hloop_run sets RUNNING), and in that state
# hloop_process_events bails out right after the poll and never runs
# hloop_process_pendings -- so the internal wakeup-fd reader never drains the
# eventfd, the fd stays readable, poll returns immediately every time, and the
# loop spins. run_forever() now flips the status to RUNNING (and back to STOP on
# exit) so the wakeup fd is drained and the loop actually blocks when idle.
# ---------------------------------------------------------------------------
@pytest.mark.skipif(
    importlib.util.find_spec("resource") is None,
    reason="resource.getrusage not available on this platform (e.g. Windows)",
)
def test_idle_loop_does_not_burn_cpu(loop):
    import resource

    def worker():
        # Make sure the wakeup eventfd is created and written at least once,
        # so a regression that only manifests after the first wakeup is caught.
        time.sleep(0.1)
        loop.call_soon_threadsafe(lambda: None)

    t = threading.Thread(target=worker)
    t.start()

    u0 = resource.getrusage(resource.RUSAGE_SELF)
    cpu0 = u0.ru_utime + u0.ru_stime

    loop.run_until_complete(asyncio.sleep(1.0))

    u1 = resource.getrusage(resource.RUSAGE_SELF)
    cpu1 = u1.ru_utime + u1.ru_stime
    t.join()

    cpu_used = cpu1 - cpu0
    # Before the fix this was ~1.0s (100% of one core). A correctly-blocking
    # idle loop uses almost nothing; allow generous headroom for CI jitter.
    assert cpu_used < 0.3, "idle loop burned {:.3f}s CPU".format(cpu_used)


def test_threadsafe_wakeup_stays_effective_across_idle_periods(loop):
    # Regression guard for "wakeup fd is read empty, then never wakes again":
    # several call_soon_threadsafe calls separated by idle periods must each
    # wake the parked poll promptly. If the wakeup-fd reader stopped draining
    # (or the fd were left permanently readable), latency would blow up or the
    # callback would never run.
    latencies = []
    done = threading.Event()
    rounds = 4

    def worker():
        for _ in range(rounds):
            time.sleep(0.1)  # let the loop fully park in poll between wakeups
            posted = time.monotonic()

            def cb(posted=posted):
                latencies.append(time.monotonic() - posted)

            loop.call_soon_threadsafe(cb)
        # Give the last callback a moment to run, then stop.
        time.sleep(0.05)
        loop.call_soon_threadsafe(loop.stop)
        done.set()

    t = threading.Thread(target=worker)
    t.start()
    loop.run_forever()
    t.join()

    assert done.is_set()
    assert len(latencies) == rounds, latencies
    for lat in latencies:
        assert lat < 0.05, "wakeup latency regressed: {!r}".format(latencies)


def test_run_after_keyboardinterrupt_rearms_running_status(loop, capfd):
    # A KeyboardInterrupt from a callback flips libhv's status back to STOP
    # (via hloop_stop) to break out of the poll. Re-entering the loop must
    # re-arm RUNNING so the loop blocks correctly again and timers still fire
    # -- otherwise the second run would busy-spin / drop IO callbacks.
    def boom():
        raise KeyboardInterrupt

    loop.call_soon(boom)
    with pytest.raises(KeyboardInterrupt):
        loop.run_until_complete(asyncio.sleep(10))

    # No "Exception ignored in: ... _on_timer" stderr noise from the C frame.
    capfd.readouterr()

    # Same loop must run cleanly again: a timer-driven sleep should complete,
    # proving the status was re-armed to RUNNING (timers + IO callbacks work).
    ran = []

    async def again():
        await asyncio.sleep(0.05)
        ran.append(True)

    loop.run_until_complete(again())
    assert ran == [True]
    assert not loop.is_running()


# ---------------------------------------------------------------------------
# Regression: a very large call_later delay must not overflow the uint32 ms
# cast (undefined behaviour). It should clamp and still be cancellable.
# ---------------------------------------------------------------------------
def test_call_later_huge_delay_clamps_and_cancels(loop):
    h = loop.call_later(1e9, lambda: None)  # ~31 years; far past libhv's cap
    assert not h.cancelled()
    h.cancel()
    assert h.cancelled()
    # Cancel must be idempotent and not crash.
    h.cancel()
