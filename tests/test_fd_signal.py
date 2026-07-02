"""M2b tests: add_reader/add_writer/remove_reader/remove_writer and Unix
signal handling (tech design plan sections 5 and 9).

Synchronous tests that construct and drive an hvloop Loop directly (same
style as test_loop.py / test_tcp.py). The watched fds are always caller-owned
socketpairs: hvloop must never close them, neither on remove_* nor on
loop.close().
"""

import asyncio
import importlib.util
import os
import signal
import socket
import sys
import threading
import time

import pytest

import hvloop


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _nonblocking_socketpair():
    a, b = socket.socketpair()
    a.setblocking(False)
    b.setblocking(False)
    return a, b


def _run_with_deadline(loop, seconds=5.0):
    """run_forever with a safety-net stop so a broken test cannot hang."""
    guard = loop.call_later(seconds, loop.stop)
    try:
        loop.run_forever()
    finally:
        guard.cancel()


# ---------------------------------------------------------------------------
# add_reader / add_writer: echo round trip
# ---------------------------------------------------------------------------
def test_reader_writer_echo_roundtrip(loop):
    # a --payload--> b (b's reader recvs) --echo--> a (a's reader collects).
    # Exercises add_writer for the initial send, add_reader on both ends, a
    # flow-controlled echo writer (add_writer/remove_writer on demand) and a
    # reader+writer registered on the same fd (a).
    a, b = _nonblocking_socketpair()
    try:
        payload = os.urandom(256 * 1024)
        chunk = 16 * 1024
        sent = 0
        echo_buf = bytearray()
        echo_writer_on = False
        back = bytearray()

        def a_writable():
            nonlocal sent
            if sent >= len(payload):
                assert loop.remove_writer(a) is True
                return
            try:
                n = a.send(payload[sent:sent + chunk])
            except BlockingIOError:
                return
            sent += n
            if sent >= len(payload):
                assert loop.remove_writer(a) is True

        def b_flush():
            nonlocal echo_writer_on
            while echo_buf:
                try:
                    n = b.send(bytes(echo_buf[:chunk]))
                except BlockingIOError:
                    break
                del echo_buf[:n]
            if echo_buf and not echo_writer_on:
                loop.add_writer(b, b_flush)
                echo_writer_on = True
            elif not echo_buf and echo_writer_on:
                assert loop.remove_writer(b) is True
                echo_writer_on = False

        def b_readable():
            try:
                data = b.recv(64 * 1024)
            except BlockingIOError:
                return
            echo_buf.extend(data)
            b_flush()

        def a_readable():
            try:
                data = a.recv(64 * 1024)
            except BlockingIOError:
                return
            back.extend(data)
            if len(back) >= len(payload):
                loop.stop()

        loop.add_writer(a, a_writable)
        loop.add_reader(b, b_readable)
        loop.add_reader(a, a_readable)
        _run_with_deadline(loop, 10.0)

        assert bytes(back) == payload
        assert loop.remove_reader(a) is True
        assert loop.remove_reader(b) is True
    finally:
        a.close()
        b.close()


def test_add_reader_replaces_previous_callback(loop):
    a, b = _nonblocking_socketpair()
    try:
        calls = []

        def old_reader():
            calls.append('old')
            b.recv(100)
            loop.stop()

        def new_reader():
            calls.append('new')
            b.recv(100)
            loop.stop()

        loop.add_reader(b, old_reader)
        loop.add_reader(b, new_reader)  # replaces old_reader
        a.send(b'x')
        _run_with_deadline(loop)
        assert calls == ['new']
    finally:
        a.close()
        b.close()


def test_add_writer_replaces_previous_callback(loop):
    a, b = _nonblocking_socketpair()
    try:
        calls = []

        def old_writer():
            calls.append('old')
            loop.stop()

        def new_writer():
            calls.append('new')
            loop.remove_writer(a)
            loop.stop()

        loop.add_writer(a, old_writer)
        loop.add_writer(a, new_writer)  # replaces old_writer
        _run_with_deadline(loop)
        assert calls == ['new']
    finally:
        a.close()
        b.close()


def test_reader_callback_gets_args_and_repeats(loop):
    # The same registration must keep firing (level-triggered) for every
    # arriving chunk, with its *args intact each time.
    a, b = _nonblocking_socketpair()
    try:
        seen = []

        def reader(tag):
            seen.append((tag, b.recv(100)))
            if len(seen) == 2:
                loop.stop()
            else:
                a.send(b'second')

        loop.add_reader(b, reader, 'tag')
        a.send(b'first')
        _run_with_deadline(loop)
        assert seen == [('tag', b'first'), ('tag', b'second')]
    finally:
        a.close()
        b.close()


# ---------------------------------------------------------------------------
# remove_reader / remove_writer semantics
# ---------------------------------------------------------------------------
def test_remove_reader_writer_return_values(loop):
    a, b = _nonblocking_socketpair()
    try:
        # Nothing registered yet.
        assert loop.remove_reader(b) is False
        assert loop.remove_writer(b) is False

        loop.add_reader(b, lambda: None)
        assert loop.remove_reader(b) is True
        assert loop.remove_reader(b) is False  # already removed

        loop.add_writer(b, lambda: None)
        assert loop.remove_writer(b) is True
        assert loop.remove_writer(b) is False
    finally:
        a.close()
        b.close()


def test_fd_accepts_fileobj_and_int(loop):
    a, b = _nonblocking_socketpair()
    try:
        loop.add_reader(b, lambda: None)          # socket object
        assert loop.remove_reader(b.fileno()) is True   # int fd
        loop.add_writer(b.fileno(), lambda: None)  # int fd
        assert loop.remove_writer(b) is True       # socket object
        with pytest.raises(ValueError):
            loop.add_reader(object(), lambda: None)
        with pytest.raises(ValueError):
            loop.add_reader(-1, lambda: None)
    finally:
        a.close()
        b.close()


def test_same_fd_reader_and_writer_independent_remove(loop):
    a, b = _nonblocking_socketpair()
    try:
        reads = []

        def reader():
            reads.append(b.recv(100))
            loop.stop()

        loop.add_reader(b, reader)
        loop.add_writer(b, lambda: None)

        # Removing the writer must not disturb the reader.
        assert loop.remove_writer(b) is True
        a.send(b'ping')
        _run_with_deadline(loop)
        assert reads == [b'ping']

        # And the reader can then be removed on its own.
        assert loop.remove_reader(b) is True
        assert loop.remove_reader(b) is False
        assert loop.remove_writer(b) is False
    finally:
        a.close()
        b.close()


def test_fd_still_usable_after_remove(loop):
    a, b = _nonblocking_socketpair()
    try:
        loop.add_reader(b, lambda: None)
        loop.add_writer(b, lambda: None)
        assert loop.remove_reader(b) is True
        assert loop.remove_writer(b) is True

        # The fd is caller-owned: it must still be open and fully usable.
        b.getsockname()  # portable "still open" check (os.fstat fails on Windows sockets)
        a.send(b'alive')
        time.sleep(0.05)
        assert b.recv(100) == b'alive'
        b.send(b'back')
        time.sleep(0.05)
        assert a.recv(100) == b'back'
    finally:
        a.close()
        b.close()


def test_fd_still_usable_after_loop_close():
    # A watcher left registered at loop.close() must be torn down without
    # closing the caller's fd (plan/M2b: fd ownership stays with the caller).
    loop = hvloop.new_event_loop()
    a, b = _nonblocking_socketpair()
    try:
        loop.add_reader(b, lambda: None)
        loop.add_writer(a, lambda: None)
        loop.close()

        a.getsockname()  # portable "still open" check (os.fstat fails on Windows sockets)
        b.getsockname()
        a.send(b'post-close')
        time.sleep(0.05)
        assert b.recv(100) == b'post-close'

        # remove_* after close: False, not an error (asyncio semantics).
        assert loop.remove_reader(b) is False
        assert loop.remove_writer(a) is False
        # add_* after close: RuntimeError.
        with pytest.raises(RuntimeError):
            loop.add_reader(b, lambda: None)
    finally:
        a.close()
        b.close()
        if not loop.is_closed():
            loop.close()


def test_reader_exception_goes_to_exception_handler(loop):
    a, b = _nonblocking_socketpair()
    try:
        contexts = []
        loop.set_exception_handler(
            lambda lp, ctx: (contexts.append(ctx), lp.stop()))

        def bad_reader():
            b.recv(100)
            raise ValueError('boom in reader')

        loop.add_reader(b, bad_reader)
        a.send(b'x')
        _run_with_deadline(loop)
        assert len(contexts) == 1
        assert isinstance(contexts[0]['exception'], ValueError)

        # The registration survives the exception (level-triggered, repeat
        # handle): another chunk fires the callback again.
        contexts.clear()
        a.send(b'y')
        _run_with_deadline(loop)
        assert len(contexts) == 1
    finally:
        a.close()
        b.close()


# ---------------------------------------------------------------------------
# no busy-polling regression
# ---------------------------------------------------------------------------
@pytest.mark.skipif(
    importlib.util.find_spec("resource") is None,
    reason="resource.getrusage not available on this platform (e.g. Windows)",
)
def test_add_reader_idle_does_not_burn_cpu(loop):
    # Level-triggered backend: with a reader registered and NO data pending,
    # an idle second must not spin the poll (revents must be cleared after
    # each dispatch, and an armed-but-quiet fd must not wake the loop).
    import resource

    a, b = _nonblocking_socketpair()
    try:
        loop.add_reader(b, lambda: None)

        u0 = resource.getrusage(resource.RUSAGE_SELF)
        cpu0 = u0.ru_utime + u0.ru_stime

        loop.run_until_complete(asyncio.sleep(1.0))

        u1 = resource.getrusage(resource.RUSAGE_SELF)
        cpu1 = u1.ru_utime + u1.ru_stime

        cpu_used = cpu1 - cpu0
        assert cpu_used < 0.3, (
            "idle loop with add_reader burned {:.3f}s CPU".format(cpu_used))
        assert loop.remove_reader(b) is True
    finally:
        a.close()
        b.close()


# ---------------------------------------------------------------------------
# Unix signals (plan section 9)
# ---------------------------------------------------------------------------
requires_unix_signals = pytest.mark.skipif(
    sys.platform == 'win32',
    reason='add_signal_handler is Unix-only (NotImplementedError on Windows)')


@requires_unix_signals
def test_signal_handler_runs_as_loop_callback(loop):
    seen = []

    def handler(tag, value):
        seen.append((tag, value, threading.get_ident()))
        loop.stop()

    loop.add_signal_handler(signal.SIGUSR1, handler, 'usr1', 42)

    fired = []

    def fire():
        signal.raise_signal(signal.SIGUSR1)
        # The Python-level handler must NOT have run synchronously here; it
        # is dispatched through the wakeup fd as a loop callback.
        fired.append(list(seen))

    loop.call_soon(fire)
    _run_with_deadline(loop)

    assert fired == [[]]  # nothing ran inside raise_signal itself
    assert seen == [('usr1', 42, threading.get_ident())]  # loop (main) thread
    assert loop.remove_signal_handler(signal.SIGUSR1) is True


@requires_unix_signals
def test_signal_handler_fires_repeatedly(loop):
    hits = []

    def handler():
        hits.append(1)
        if len(hits) >= 3:
            loop.stop()
        else:
            loop.call_soon(signal.raise_signal, signal.SIGUSR1)

    loop.add_signal_handler(signal.SIGUSR1, handler)
    loop.call_soon(signal.raise_signal, signal.SIGUSR1)
    _run_with_deadline(loop)
    assert len(hits) == 3
    assert loop.remove_signal_handler(signal.SIGUSR1) is True


@requires_unix_signals
def test_remove_signal_handler_stops_dispatch(loop):
    hits = []
    loop.add_signal_handler(signal.SIGUSR1, hits.append, 'never')
    assert loop.remove_signal_handler(signal.SIGUSR1) is True
    assert loop.remove_signal_handler(signal.SIGUSR1) is False

    # remove restored SIG_DFL (default for SIGUSR1 would kill the process on
    # a real delivery), so install a plain recording handler before raising.
    assert signal.getsignal(signal.SIGUSR1) is signal.SIG_DFL
    plain = []
    signal.signal(signal.SIGUSR1, lambda s, f: plain.append(s))
    try:
        loop.call_soon(signal.raise_signal, signal.SIGUSR1)
        loop.call_later(0.2, loop.stop)
        _run_with_deadline(loop)
        assert hits == []  # loop handler no longer registered
        assert plain == [signal.SIGUSR1]  # the plain handler got it instead
    finally:
        signal.signal(signal.SIGUSR1, signal.SIG_DFL)


@requires_unix_signals
def test_sigint_handler_stops_run_forever(loop):
    loop.add_signal_handler(signal.SIGINT, loop.stop)
    loop.call_soon(signal.raise_signal, signal.SIGINT)
    guard = loop.call_later(5.0, loop.stop)
    loop.run_forever()  # must return normally, no KeyboardInterrupt
    guard.cancel()

    # asyncio semantics: removing the SIGINT handler restores
    # default_int_handler (not SIG_DFL).
    assert loop.remove_signal_handler(signal.SIGINT) is True
    assert signal.getsignal(signal.SIGINT) is signal.default_int_handler


@requires_unix_signals
def test_add_signal_handler_rejects_coroutines(loop):
    async def coro_func():
        pass

    with pytest.raises(TypeError):
        loop.add_signal_handler(signal.SIGUSR1, coro_func)

    coro = coro_func()
    try:
        with pytest.raises(TypeError):
            loop.add_signal_handler(signal.SIGUSR1, coro)
    finally:
        coro.close()

    # Neither attempt may have touched the signal disposition.
    assert signal.getsignal(signal.SIGUSR1) is signal.SIG_DFL


@requires_unix_signals
def test_signal_argument_validation(loop):
    with pytest.raises(TypeError):
        loop.add_signal_handler('SIGUSR1', lambda: None)
    with pytest.raises(ValueError):
        loop.add_signal_handler(0, lambda: None)
    with pytest.raises(ValueError):
        loop.add_signal_handler(max(signal.valid_signals()) + 1000,
                                lambda: None)
    with pytest.raises(TypeError):
        loop.remove_signal_handler('SIGUSR1')
    with pytest.raises(ValueError):
        loop.remove_signal_handler(0)


@requires_unix_signals
def test_add_signal_handler_from_non_main_thread_raises(loop):
    result = {}

    def worker():
        try:
            loop.add_signal_handler(signal.SIGUSR1, lambda: None)
        except BaseException as exc:  # noqa: BLE001
            result['exc'] = exc

    t = threading.Thread(target=worker)
    t.start()
    t.join()
    # set_wakeup_fd is main-thread-only; surfaced as RuntimeError (asyncio
    # semantics).
    assert isinstance(result.get('exc'), RuntimeError)
    assert signal.getsignal(signal.SIGUSR1) is signal.SIG_DFL


@requires_unix_signals
def test_add_signal_handler_after_close_raises(loop):
    loop.close()
    with pytest.raises(RuntimeError):
        loop.add_signal_handler(signal.SIGUSR1, lambda: None)


@requires_unix_signals
def test_close_restores_signal_state():
    loop = hvloop.new_event_loop()
    try:
        loop.add_signal_handler(signal.SIGUSR1, lambda: None)
        loop.add_signal_handler(signal.SIGINT, lambda: None)
        loop.close()

        # Dispositions restored per asyncio semantics.
        assert signal.getsignal(signal.SIGUSR1) is signal.SIG_DFL
        assert signal.getsignal(signal.SIGINT) is signal.default_int_handler
        # The wakeup fd was restored: installing "none" returns the previous
        # value, which must be -1 (i.e. not our — now closed — socketpair).
        assert signal.set_wakeup_fd(-1) == -1
    finally:
        if not loop.is_closed():
            loop.close()


@requires_unix_signals
def test_signal_handler_survives_across_runs(loop):
    # The registration persists over run_forever() invocations.
    hits = []

    def handler():
        hits.append(1)
        loop.stop()

    loop.add_signal_handler(signal.SIGUSR1, handler)
    for _ in range(2):
        loop.call_soon(signal.raise_signal, signal.SIGUSR1)
        _run_with_deadline(loop)
    assert len(hits) == 2
    assert loop.remove_signal_handler(signal.SIGUSR1) is True
