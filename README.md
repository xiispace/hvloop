# hvloop
[![PyPI](https://img.shields.io/pypi/v/hvloop.svg)](https://pypi.python.org/pypi/hvloop)

hvloop is a drop-in asyncio event loop — like [uvloop](https://github.com/MagicStack/uvloop),
but built on [libhv](https://github.com/ithewei/libhv) instead of libuv. It is a
Cython extension that drives libhv's cross-platform event engine (epoll on Linux,
kqueue on macOS, wepoll/IOCP on Windows) and exposes the asyncio loop API, aimed
at web-server workloads: it runs FastAPI/ASGI apps under uvicorn, including
WebSocket and TLS.

> **Status:** alpha. The full test suite passes on macOS/Linux and hvloop runs
> real uvicorn + FastAPI workloads, but it has not been battle-tested in
> production yet. Windows is covered by CI but less exercised. UDP, subprocess
> and pipe transports are not implemented.

## Installation
hvloop requires Python 3.10 or greater.
```shell
$ pip install hvloop
```

## Quickstart

Install hvloop as the global asyncio event loop policy, then use asyncio as usual:

```python
import asyncio
import hvloop

hvloop.install()

async def main():
    await asyncio.sleep(1)
    print("hello from hvloop")

asyncio.run(main())
```

Or run a coroutine directly on a fresh hvloop loop (no global policy change):

```python
import asyncio
import hvloop

async def main():
    await asyncio.sleep(1)

hvloop.run(main())                      # like asyncio.run(), but on hvloop

# equivalently, on Python 3.11+:
with asyncio.Runner(loop_factory=hvloop.new_event_loop) as runner:
    runner.run(main())
```

## Running uvicorn + FastAPI on hvloop

hvloop implements the asyncio TCP transport / server / signal APIs that uvicorn
needs, so a FastAPI app (HTTP **and** WebSocket) runs on it unchanged. There are
three supported ways to wire it up.

> **Heads-up (uvicorn >= 0.36):** uvicorn no longer consults the asyncio
> event-loop *policy* — `Config.get_loop_factory()` maps `loop="asyncio"`
> straight to `asyncio.SelectorEventLoop`. The classic
> `hvloop.install()` + `uvicorn.run(app, loop="asyncio")` recipe therefore
> **silently runs on stock asyncio, not hvloop**. Use one of the wirings below.

### 1. Recommended: `loop="hvloop:new_event_loop"`

uvicorn accepts any `"module:callable"` string as a loop *factory*.
`hvloop.new_event_loop` is exactly that — no glue code needed:

```python
import uvicorn
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
async def root():
    return {"hello": "hvloop"}

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, loop="hvloop:new_event_loop")
```

Same thing from the uvicorn CLI:

```shell
$ uvicorn examples.fastapi_app:app --loop hvloop:new_event_loop
```

### 2. Policy-based: `hvloop.install()` + `loop="none"`

`loop="none"` makes uvicorn use no explicit loop factory, so its runner falls
back to `asyncio.new_event_loop()` — which *does* consult the event-loop
policy that `hvloop.install()` sets:

```python
import hvloop
import uvicorn

hvloop.install()   # asyncio.new_event_loop() now returns hvloop loops
uvicorn.run(app, host="127.0.0.1", port=8000, loop="none")
```

Note: the asyncio policy system is deprecated (Python 3.14 warns; removal is
slated for 3.16), so `hvloop.install()` emits a `DeprecationWarning` on 3.14.
Prefer wiring 1 for new code.

### 3. Run `Server.serve()` on an hvloop loop you own

Useful when you drive the loop yourself (e.g. a client and server on the same
loop, as the test suite does). `server.serve()` runs on whatever loop awaits
it — uvicorn's `loop=` setting is never used to create one in this mode:

```python
import asyncio
import hvloop
import uvicorn
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
async def root():
    return {"hello": "hvloop"}

async def main():
    config = uvicorn.Config(app, host="127.0.0.1", port=8000)
    server = uvicorn.Server(config)
    await server.serve()               # runs on the current (hvloop) loop

hvloop.run(main())
```

A complete runnable example (HTTP endpoints, a streaming response, lifespan
events and a WebSocket echo endpoint) lives in
[`examples/fastapi_app.py`](examples/fastapi_app.py):

```shell
$ python examples/fastapi_app.py
```

## Implemented features

hvloop currently implements:

- the full loop lifecycle, scheduling (`call_soon`/`call_later`/`call_at`/
  `call_soon_threadsafe`), timers, executors and `getaddrinfo`/`getnameinfo`;
- TCP: `create_connection`, `create_server` (host/port and `sock=`), the
  `asyncio.Transport` surface, and `Server` (`close`/`wait_closed`/
  `serve_forever`/`sockets`);
- TLS: `create_server(ssl=...)` and `create_connection(ssl=...,
  server_hostname=...)` including `ssl_handshake_timeout` /
  `ssl_shutdown_timeout` (3.11+), built on the stdlib
  `asyncio.sslproto.SSLProtocol` (MemoryBIO), so any `ssl.SSLContext`
  works unchanged — `uvicorn --ssl-certfile/--ssl-keyfile` included;
- `sock_recv` / `sock_recv_into` / `sock_sendall` / `sock_connect` /
  `sock_accept`;
- `add_reader`/`add_writer`/`remove_reader`/`remove_writer`;
- Unix signal handling (`add_signal_handler`/`remove_signal_handler`).

UDP (`create_datagram_endpoint`), subprocess and pipe APIs are not
implemented yet.

## Benchmarks

Numbers from a single machine — treat them as loop-vs-loop comparisons,
not absolute capacity. Environment: macOS 26.5 (arm64, Apple Silicon),
CPython 3.14.0, hvloop 0.2.0, uvloop 0.22.1, uvicorn 0.49 (h11);
server and load generator share the machine. Reproduce with the scripts
in [`benchmarks/`](benchmarks/).

**TCP echo** — `benchmarks/bench_tcp_echo.py --rounds 500`: one loop runs
the echo server plus 100 client connections, each doing 500 sequential
10 KiB round trips (best of 3):

| loop    | roundtrips/s | MiB/s  | vs asyncio |
|---------|-------------:|-------:|-----------:|
| asyncio |      129,812 | 2535.4 |      1.00x |
| hvloop  |      126,985 | 2480.2 |      0.98x |
| uvloop  |      169,331 | 3307.3 |      1.30x |

**uvicorn hello-world RPS** — `benchmarks/bench_http.py`: raw-ASGI
hello-world served by `uvicorn.run(loop=...)` in a subprocess, loaded by a
self-contained keep-alive HTTP client (50 connections, 5 s window):

| loop    |    RPS | vs asyncio |
|---------|-------:|-----------:|
| asyncio | 23,068 |      1.00x |
| hvloop  | 24,785 |      1.07x |
| uvloop  | 29,969 |      1.30x |
