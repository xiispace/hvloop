# CLAUDE.md

Guidance for working in the hvloop repository.

## What this is

hvloop is a drop-in asyncio event loop (like uvloop) implemented as a **Cython
extension** on top of the vendored C library **libhv** (`vendor/libhv`, a git
submodule). Target use case: web servers — it runs FastAPI/ASGI under uvicorn,
including WebSocket and TLS. Cross-platform: Linux (epoll), macOS (kqueue),
Windows (wepoll).

The authoritative design is `docs/plans/2026-06-13-hvloop-tech-design.md`. Read
it before making non-trivial changes — it explains *why* the loop is driven the
way it is.

## Layout

- `src/hvloop/_core.pyx` — **everything native lives here in one compilation
  unit** (the loop, `TCPTransport`, `Server`, `_TCPListener`, `_FDWatcher`,
  TLS wiring, `sock_*`, signals, and all libhv C callbacks). ~3000 lines.
- `src/hvloop/includes/hv.pxd` — libhv C API declarations (subset we use).
  Truth source for the C API is `vendor/libhv/event/hloop.h`.
- `src/hvloop/hvloop_shim.h` — small `static inline` C helpers for things the
  public libhv API doesn't expose (reaching private struct fields, etc.).
- `src/hvloop/__init__.py` — Python-level public API: `Loop`,
  `EventLoopPolicy`, `install()`/`uninstall()`, `new_event_loop()`, `run()`.
- `tests/` — pytest suite (synchronous test functions that build their own
  loop; `tests/certs/` holds committed self-signed certs for TLS tests).
- `benchmarks/`, `examples/fastapi_app.py` — runnable perf scripts and a demo.
- `CMakeLists.txt` + `pyproject.toml` — scikit-build-core + cython-cmake build;
  libhv is compiled as a static lib with only its core event engine enabled.

## Build & test

```shell
# Editable install (rebuilds the extension). Run after any .pyx/.pxd/.h change.
uv pip install -e .

# Full suite (expect 149 passing).
.venv/bin/python -m pytest tests/ -q

# Faster inner loop without reinstalling: build + install the target directly.
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DSKBUILD_PROJECT_NAME=hvloop \
  -DSKBUILD_PROJECT_VERSION=0.2.0 -DPython_EXECUTABLE=$PWD/.venv/bin/python
cmake --build build --target _core -j
cmake --install build --component python_modules --prefix src
PYTHONPATH=src .venv/bin/python -m pytest

# Wheel/sdist.
uv build
```

Environment here: macOS arm64, venv at `.venv` (Python 3.14). Editing a `.pyx`
and re-running pytest **without rebuilding tests stale code** — always rebuild
first.

## Core invariants — do not break these

These were hard-won during development; violating them causes crashes, leaks,
or busy-spins that tests may not immediately catch.

1. **The loop is self-driven; we do NOT call `hloop_run`.** `run_forever()`
   loops manually: run a snapshot of the `_ready` deque, then
   `hloop_process_events(timeout)` with `timeout=0` when ready is non-empty
   else a large cap. libhv clamps the poll to the nearest timer internally.

2. **libhv's loop status must be forced to RUNNING while we drive it.**
   `hloop_process_events` returns early (skipping pending-event dispatch) when
   status is `STOP`, which is the initial value since we never call
   `hloop_run`. `run_forever()` calls `hvloop_set_status_running()` on entry and
   `hvloop_set_status_stop()` on exit (in `hvloop_shim.h`). Without this the
   wakeup fd never drains and the loop busy-spins at 100% CPU.

3. **Create the wakeup eventfd before the first poll.** `run_forever()` calls
   `hloop_wakeup()` once up front; otherwise libhv sleeps in an un-wakeable
   `hv_msleep` when there are no ios and `call_soon_threadsafe` can't interrupt.

4. **`hloop_new(0)`** — pass 0 explicitly so `HLOOP_FLAG_AUTO_FREE` is off,
   else libhv double-frees against our `hloop_free()` in `close()`.

5. **Every libhv C callback is `noexcept nogil` + `with gil` + full try/except.**
   No Python exception may propagate back into C. KeyboardInterrupt/SystemExit
   raised inside a callback are stashed on `loop._pending_exc` and re-raised by
   `run_forever` after the poll returns (they can't cross the `noexcept` frame).

6. **Reference discipline for anything registered with libhv.** Objects handed
   to libhv (timers, transports, listeners, fd watchers) do `Py_INCREF` at
   registration and are tracked in a loop-level set (`_timer_handles`,
   `_hio_objs`, `_fd_watchers`). There is exactly **one** release path per
   object — the close/cancel dispatch and `loop.close()` teardown are mutually
   exclusive and each nulls the C pointer before `Py_DECREF`. `loop.close()`
   must tear all of these down *before* `hloop_free`. Getting this wrong = UAF
   or leak (both happened and were fixed; regression tests guard them).

7. **libhv's read buffer is loop-level shared memory.** In a read callback,
   copy the bytes immediately (`PyBytes_FromStringAndSize`) before handing to
   the protocol — the buffer is reused as soon as the callback returns.

8. **fd ownership.** fds we create (`create_connection`, host/port
   `create_server`) are handed to libhv via `sock.detach()` and libhv closes
   them. Caller-owned fds (`create_server(sock=)`, `add_reader/writer`, signal
   socketpair read end) are never closed by us — teardown uses
   `hvloop_hio_release_external` (resets io type so `hio_close` skips the fd).

## Gotchas / decisions worth knowing

- **uvicorn ≥ 0.36 ignores the asyncio policy.** `loop="asyncio"` maps straight
  to `SelectorEventLoop`; `hvloop.install()` has no effect there. Wire uvicorn
  with `loop="hvloop:new_event_loop"` (recommended) or `loop="none"` +
  `hvloop.install()`. See the README for all three wirings.
- **TLS reuses stdlib `asyncio.sslproto.SSLProtocol`** (MemoryBIO), *not*
  libhv's OpenSSL. This keeps any `ssl.SSLContext` working and avoids an
  OpenSSL link/distribution dependency. libhv is built with `WITH_OPENSSL=OFF`.
  Code is version-gated (`_PY311`) for the 3.10 vs 3.11+ sslproto differences.
- **`add_reader`/`add_writer` replace libhv's io callback.** We `hio_add` our
  own raw callback (libhv then won't read/write the fd itself) and translate
  `hio_revents` into the reader/writer handles, clearing revents afterward
  (mirrors `nio.c`'s `hio_handle_events`). A watched fd must not also be a
  transport, and high-level `hio_read`/`hio_write` must not be used on it.
- **No half-close.** libhv closes on EOF, so `eof_received()` returning True
  can't keep the transport open; `connection_lost` always follows. Fine for
  HTTP/WebSocket. Documented deviation from asyncio.
- **Signals (Unix only):** `set_wakeup_fd` + a socketpair registered as an
  internal reader. Windows raises `NotImplementedError` (uvicorn falls back to
  `signal.signal`, same as asyncio's Proactor loop).

## Known Windows limitations

CI runs the full matrix (Linux/macOS/Windows × py3.10/3.14). Windows-specific
notes:

- **Signals are Unix-only** — `add_signal_handler`/`remove_signal_handler` raise
  `NotImplementedError`; those tests are skipped on Windows (uvicorn falls back
  to `signal.signal`, same as asyncio's Proactor loop).
- **Write-buffer backpressure is unverified on Windows.** Two flow-control
  tests (`test_write_flow_control`, `test_close_flushes_pending_writes`) assert
  that a large `write()` to a paused/slow peer leaves data in libhv's write
  queue (`get_write_buffer_size() > 0`). On Windows loopback the payload is
  absorbed by the larger default socket buffers (and/or libhv's Windows
  write-queue accounting differs), so the buffer reads 0 and `pause_writing`
  doesn't fire in the test. These are marked `xfail(strict=False)` on Windows.
  **Open question for a Windows maintainer:** does watermark flow control
  actually engage under real backpressure on Windows, or is this a genuine gap?
  Needs verification on real hardware (shrinking SO_SNDBUF/SO_RCVBUF in the test
  is the likely fix if it's just buffer sizing).
- `os.fstat()` does **not** work on Windows socket handles (they aren't CRT
  fds) — use `sock.getsockname()` for "is this socket still open" checks in
  tests.

## Conventions

- `vendor/libhv/` is **read-only** — never modify it. It's a submodule pinned
  to a specific commit. Reach private internals via `hvloop_shim.h`.
- Don't edit `docs/plans/` design docs unless changing the design deliberately.
- Match the existing code style in `_core.pyx` (dense comments explaining *why*
  at every non-obvious libhv interaction; module-level aliases for hot-path
  attribute lookups).
- New native features generally include their own pytest coverage; the test
  suite is the acceptance bar.
