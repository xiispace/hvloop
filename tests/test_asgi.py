"""M3 ASGI acceptance tests: uvicorn + FastAPI (HTTP & WebSocket) on hvloop.

Plan section 12.3 (the acceptance gate): a real uvicorn server serving a real
FastAPI app over real TCP, driven together with real clients (httpx for HTTP,
the ``websockets`` library for WebSocket) -- everything on ONE hvloop event
loop.

Harness design
--------------
Each test uses the synchronous ``loop`` fixture (a fresh ``hvloop`` loop) and
drives an ``async def main()`` via ``loop.run_until_complete``. Inside, we run
``uvicorn.Server(Config(...)).serve()`` as a task on that very loop and talk to
it from httpx/websockets clients on the same loop. Both the inbound
(create_server) and outbound (create_connection) TCP paths are thus exercised
at once. In this serve()-as-task mode uvicorn never creates a loop itself
(``Config.get_loop_factory()`` is not consulted), so no policy juggling is
needed and the suite avoids ``asyncio.set_event_loop_policy`` -- deprecated on
Python 3.14.

uvicorn's OWN loop construction (``Server.run()`` -> ``get_loop_factory()`` +
``asyncio_run``) is covered separately by the wiring regression tests at the
bottom of this file. NOTE: with uvicorn >= 0.36, ``loop="asyncio"`` maps
directly to ``asyncio.SelectorEventLoop`` and ignores the event-loop policy;
the supported production wirings are ``loop="hvloop:new_event_loop"``
(recommended, used by ``examples/fastapi_app.py``) and ``hvloop.install()`` +
``loop="none"`` -- both documented in the README.
"""

from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import signal
import socket
import sys
import threading
import time

import pytest

# The ASGI stack is an optional test-only dependency (pyproject [test] extra).
# Skip the whole module cleanly rather than error if it is missing.
fastapi = pytest.importorskip("fastapi")
httpx = pytest.importorskip("httpx")
uvicorn = pytest.importorskip("uvicorn")
websockets = pytest.importorskip("websockets")

from fastapi import FastAPI, WebSocket, WebSocketDisconnect  # noqa: E402
from fastapi.responses import StreamingResponse  # noqa: E402


# ---------------------------------------------------------------------------
# HTTP protocol matrix: h11 is always available; add httptools when installed
# so we cover both of uvicorn's HTTP implementations against our transport.
# ---------------------------------------------------------------------------
HTTP_PROTOCOLS = ["h11"]
if importlib.util.find_spec("httptools") is not None:
    HTTP_PROTOCOLS.append("httptools")


# ---------------------------------------------------------------------------
# App under test
# ---------------------------------------------------------------------------
def make_app(lifespan_events=None):
    """Build a FastAPI app. If ``lifespan_events`` (a list) is given, append
    "startup"/"shutdown" markers to it around ``yield`` so lifespan ordering
    can be asserted."""
    lifespan = None
    if lifespan_events is not None:
        @contextlib.asynccontextmanager
        async def lifespan(_app):  # noqa: F811
            lifespan_events.append("startup")
            try:
                yield
            finally:
                lifespan_events.append("shutdown")

    app = FastAPI(lifespan=lifespan)

    @app.get("/json")
    async def json_endpoint():
        return {"framework": "fastapi", "value": 123}

    @app.get("/items/{item_id}")
    async def read_item(item_id: int, q: str | None = None):
        # Path param is coerced to int by FastAPI; query param is optional.
        return {"item_id": item_id, "q": q, "doubled": item_id * 2}

    @app.get("/async")
    async def async_endpoint():
        return {"mode": "async", "on_main_thread": _is_main_thread()}

    @app.get("/sync")
    def sync_endpoint():
        # Starlette runs plain ``def`` endpoints in a worker thread; proving we
        # are NOT on the loop/main thread shows the thread pool path works.
        return {"mode": "sync", "on_main_thread": _is_main_thread()}

    @app.get("/stream")
    async def stream_endpoint():
        async def gen():
            for i in range(5):
                yield f"chunk{i}\n".encode()
                await asyncio.sleep(0)
        return StreamingResponse(gen(), media_type="text/plain")

    @app.websocket("/ws")
    async def ws_echo(ws: WebSocket):
        await ws.accept()
        try:
            while True:
                msg = await ws.receive_text()
                await ws.send_text("echo:" + msg)
        except WebSocketDisconnect:
            pass

    return app


def _is_main_thread():
    return threading.current_thread() is threading.main_thread()


# Shared app for the stateless tests (built once).
APP = make_app()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@contextlib.asynccontextmanager
async def running_server(app, **config_kwargs):
    """Start ``uvicorn`` serving ``app`` as a task on the current hvloop loop,
    yield ``(server, port)`` once it is up, and shut it down gracefully via
    ``should_exit`` on exit."""
    port = _free_port()
    # No ``loop=`` setting: serve() runs on the caller's (hvloop) loop, so
    # Config.get_loop_factory() is never consulted in this mode.
    config = uvicorn.Config(
        app,
        host="127.0.0.1",
        port=port,
        log_level="warning",
        **config_kwargs,
    )
    server = uvicorn.Server(config)
    task = asyncio.get_running_loop().create_task(server.serve())
    try:
        deadline = time.monotonic() + 10.0
        while not server.started:
            if task.done():
                task.result()  # re-raise a startup failure, if any
                raise RuntimeError("uvicorn task ended before startup")
            if time.monotonic() > deadline:
                raise TimeoutError("uvicorn did not start within 10s")
            await asyncio.sleep(0.01)
        yield server, port
    finally:
        server.should_exit = True
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(asyncio.shield(task), timeout=10.0)
        if not task.done():
            task.cancel()
            with contextlib.suppress(BaseException):
                await task


# ---------------------------------------------------------------------------
# HTTP: JSON, path/query params, async vs sync (thread pool), streaming
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("http_protocol", HTTP_PROTOCOLS)
def test_http_json_endpoint(loop, http_protocol):
    async def main():
        async with running_server(APP, http=http_protocol) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                r = await client.get("/json")
                assert r.status_code == 200
                assert r.json() == {"framework": "fastapi", "value": 123}

    loop.run_until_complete(main())


@pytest.mark.parametrize("http_protocol", HTTP_PROTOCOLS)
def test_http_path_and_query_params(loop, http_protocol):
    async def main():
        async with running_server(APP, http=http_protocol) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                r = await client.get("/items/42", params={"q": "hello"})
                assert r.status_code == 200
                assert r.json() == {"item_id": 42, "q": "hello", "doubled": 84}

                # Missing optional query param.
                r = await client.get("/items/7")
                assert r.json() == {"item_id": 7, "q": None, "doubled": 14}

                # Bad path param type -> FastAPI validation error (422).
                r = await client.get("/items/not-an-int")
                assert r.status_code == 422

    loop.run_until_complete(main())


def test_http_async_and_sync_endpoints(loop):
    """async def endpoints run on the loop (main) thread; plain def endpoints
    run in the thread pool (not the main thread)."""
    async def main():
        async with running_server(APP) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                ra = await client.get("/async")
                assert ra.status_code == 200
                assert ra.json() == {"mode": "async", "on_main_thread": True}

                rs = await client.get("/sync")
                assert rs.status_code == 200
                body = rs.json()
                assert body["mode"] == "sync"
                assert body["on_main_thread"] is False

    loop.run_until_complete(main())


def test_http_streaming_response(loop):
    async def main():
        async with running_server(APP) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                expected = b"".join(f"chunk{i}\n".encode() for i in range(5))

                # Buffered read.
                r = await client.get("/stream")
                assert r.status_code == 200
                assert r.content == expected
                # No Content-Length -> chunked transfer encoding.
                assert "content-length" not in r.headers

                # Incremental streaming read: collect chunks as they arrive.
                collected = bytearray()
                async with client.stream("GET", "/stream") as resp:
                    assert resp.status_code == 200
                    async for chunk in resp.aiter_bytes():
                        collected.extend(chunk)
                assert bytes(collected) == expected

    loop.run_until_complete(main())


def test_http_concurrent_requests(loop):
    """Many concurrent in-flight requests on one loop stay correct."""
    async def main():
        async with running_server(APP) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                results = await asyncio.gather(
                    *(client.get(f"/items/{i}") for i in range(25))
                )
                for i, r in enumerate(results):
                    assert r.status_code == 200
                    assert r.json()["item_id"] == i

    loop.run_until_complete(main())


# ---------------------------------------------------------------------------
# Lifespan startup/shutdown ordering
# ---------------------------------------------------------------------------
def test_lifespan_startup_shutdown_order(loop):
    events: list[str] = []
    app = make_app(lifespan_events=events)

    async def main():
        async with running_server(app, lifespan="on") as (_server, port):
            # startup must have fired before we can serve a request.
            assert events == ["startup"]
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                r = await client.get("/json")
                assert r.status_code == 200
            # shutdown has not fired yet (server still running).
            assert events == ["startup"]
        # After graceful shutdown the shutdown event has fired, in order.
        assert events == ["startup", "shutdown"]

    loop.run_until_complete(main())


# ---------------------------------------------------------------------------
# WebSocket: echo, and two concurrent connections that don't cross-talk
# ---------------------------------------------------------------------------
def test_websocket_echo(loop):
    async def main():
        async with running_server(APP) as (_server, port):
            uri = f"ws://127.0.0.1:{port}/ws"
            async with websockets.connect(uri) as ws:
                await ws.send("hello")
                assert await ws.recv() == "echo:hello"
                await ws.send("world")
                assert await ws.recv() == "echo:world"

    loop.run_until_complete(main())


def test_websocket_two_connections_isolated(loop):
    async def main():
        async with running_server(APP) as (_server, port):
            uri = f"ws://127.0.0.1:{port}/ws"
            async with websockets.connect(uri) as a, websockets.connect(uri) as b:
                # Interleave sends; each connection must only see its own echoes.
                await a.send("a1")
                await b.send("b1")
                assert await a.recv() == "echo:a1"
                assert await b.recv() == "echo:b1"

                await b.send("b2")
                await a.send("a2")
                assert await b.recv() == "echo:b2"
                assert await a.recv() == "echo:a2"

    loop.run_until_complete(main())


# ---------------------------------------------------------------------------
# Graceful exit: should_exit returns serve() and frees the port
# ---------------------------------------------------------------------------
def test_graceful_should_exit_releases_port(loop):
    async def main():
        async with running_server(APP) as (_server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                assert (await client.get("/json")).status_code == 200
        # Server has stopped; the listen port must be free to rebind.
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
        finally:
            s.close()
        return port

    loop.run_until_complete(main())


# ---------------------------------------------------------------------------
# Graceful exit via SIGINT (uvicorn's default signal path)
#
# uvicorn 0.49's Server.capture_signals() installs signal.signal(SIGINT,
# handle_exit) directly (not loop.add_signal_handler) whenever serve() runs on
# the main thread, and RE-RAISES any captured signal after serve() returns. We
# install a no-op SIGINT handler first so (a) that no-op is what capture_signals
# saves/restores and (b) the trailing re-raise hits the no-op instead of
# KeyboardInterrupt, then restore the real handler in finally.
# ---------------------------------------------------------------------------
@pytest.mark.skipif(
    sys.platform == "win32", reason="POSIX signal semantics (plan section 9)"
)
def test_sigint_graceful_return(loop):
    async def main():
        async with running_server(APP) as (server, port):
            async with httpx.AsyncClient(
                base_url=f"http://127.0.0.1:{port}"
            ) as client:
                assert (await client.get("/json")).status_code == 200
            # Deliver SIGINT: uvicorn's handle_exit sets should_exit=True and
            # main_loop() notices it on its next 0.1s tick, so serve() returns.
            signal.raise_signal(signal.SIGINT)
            deadline = time.monotonic() + 10.0
            while not server.should_exit:
                if time.monotonic() > deadline:
                    raise TimeoutError("SIGINT did not set should_exit")
                await asyncio.sleep(0.01)
            # running_server's __aexit__ then awaits serve() to completion.

    prev = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGINT, lambda *_a: None)
    try:
        loop.run_until_complete(main())
    finally:
        signal.signal(signal.SIGINT, prev)


# ---------------------------------------------------------------------------
# Outbound: httpx.AsyncClient against the local uvicorn server exercises the
# create_connection() client path (this is what M3's "出站请求" gate calls for;
# every HTTP test above also goes through it, this one asserts it explicitly).
# ---------------------------------------------------------------------------
def test_outbound_httpx_create_connection(loop):
    async def main():
        async with running_server(APP) as (_server, port):
            async with httpx.AsyncClient() as client:
                # Full absolute URL, default (create_connection-backed) transport.
                r = await client.get(f"http://127.0.0.1:{port}/json")
                assert r.status_code == 200
                assert r.json()["framework"] == "fastapi"
                # Keep-alive reuse: a second request on the same connection.
                r2 = await client.get(f"http://127.0.0.1:{port}/async")
                assert r2.status_code == 200

    loop.run_until_complete(main())


# ---------------------------------------------------------------------------
# Loop-factory wiring regression tests
#
# All tests above run serve() as a task on an already-running hvloop loop, so
# they never exercise uvicorn's own loop construction. uvicorn >= 0.36 replaced
# the policy mechanism with Config.get_loop_factory(): ``loop="asyncio"`` maps
# DIRECTLY to asyncio.SelectorEventLoop, so the old ``hvloop.install()`` +
# ``loop="asyncio"`` recipe silently falls back to stock asyncio. These tests
# drive uvicorn's real entry point -- Server.run(), i.e. get_loop_factory() +
# asyncio_run() -- in a subthread and assert, over real HTTP, that the loop
# serving the request is an hvloop Loop for both supported wirings:
#   1. loop="hvloop:new_event_loop"   (custom "module:callable" factory string)
#   2. loop="none" + hvloop.install() (no factory -> asyncio.new_event_loop()
#      -> event-loop policy)
# ---------------------------------------------------------------------------
async def _loopclass_app(scope, receive, send):
    """Tiny ASGI app: responds with the running loop's qualified class name."""
    assert scope["type"] == "http"
    cls = type(asyncio.get_running_loop())
    body = f"{cls.__module__}.{cls.__qualname__}".encode()
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain")],
    })
    await send({"type": "http.response.body", "body": body})


def _run_uvicorn_in_thread_and_probe(loop_setting):
    """Start uvicorn via Server.run() (the real get_loop_factory/asyncio_run
    path) in a subthread, GET the loop-class probe over real TCP, shut down
    via should_exit, and return the reported loop class name."""
    port = _free_port()
    config = uvicorn.Config(
        _loopclass_app,
        host="127.0.0.1",
        port=port,
        loop=loop_setting,
        lifespan="off",
        log_level="warning",
    )
    server = uvicorn.Server(config)
    # Not the main thread -> capture_signals() is a no-op (no signal handlers
    # are touched from the subthread).
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 10.0
        while not server.started:
            if not thread.is_alive():
                raise RuntimeError("uvicorn thread died during startup")
            if time.monotonic() > deadline:
                raise TimeoutError("uvicorn did not start within 10s")
            time.sleep(0.01)
        resp = httpx.get(f"http://127.0.0.1:{port}/", timeout=10.0)
        assert resp.status_code == 200
        return resp.text
    finally:
        server.should_exit = True
        thread.join(timeout=10.0)
        assert not thread.is_alive(), "uvicorn thread did not exit"


def test_uvicorn_run_with_hvloop_factory_string():
    """loop="hvloop:new_event_loop" makes uvicorn itself build an hvloop loop
    (the recommended wiring; zero glue, no policy involved)."""
    loop_class = _run_uvicorn_in_thread_and_probe("hvloop:new_event_loop")
    assert loop_class == "hvloop.Loop", loop_class


def test_uvicorn_run_with_policy_and_loop_none():
    """loop="none" + hvloop.install(): uvicorn uses no explicit factory, so
    its runner falls back to asyncio.new_event_loop(), which consults the
    policy hvloop.install() set."""
    import hvloop

    hvloop.install()
    try:
        loop_class = _run_uvicorn_in_thread_and_probe("none")
    finally:
        hvloop.uninstall()   # restore the default policy for other tests
    assert loop_class == "hvloop.Loop", loop_class
