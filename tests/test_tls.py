"""M4 TLS tests (tech design section 8).

hvloop reuses the stdlib asyncio.sslproto.SSLProtocol on top of its own
TCPTransport; these tests drive server and client both on ONE hvloop loop:

  * TLS echo (create_server(ssl=...) + create_connection(ssl=...))
  * 1MB+ payload round trip
  * handshake failure (untrusted server certificate) surfaces sensible
    exceptions on both sides
  * get_extra_info('ssl_object' / 'peercert' / 'sslcontext')
  * write flow control under TLS does not deadlock (streams drain())
  * uvicorn --ssl integration smoke (see test_asgi.py for the harness)

Certificates: tests/certs/server.{crt,key} -- a committed self-signed pair
with SAN localhost/127.0.0.1/::1 (see tests/certs/README.md for why the
vendor/libhv cert is unusable: it has no SAN, so Python hostname
verification can never pass).
"""

from __future__ import annotations

import asyncio
import pathlib
import socket
import ssl
import sys

import pytest

CERT_DIR = pathlib.Path(__file__).parent / "certs"
SERVER_CERT = str(CERT_DIR / "server.crt")
SERVER_KEY = str(CERT_DIR / "server.key")


def _server_ctx() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(SERVER_CERT, SERVER_KEY)
    return ctx


def _client_ctx() -> ssl.SSLContext:
    # Default (verifying) client context that trusts our self-signed cert.
    ctx = ssl.create_default_context(cafile=SERVER_CERT)
    return ctx


class _Echo(asyncio.Protocol):
    """Server-side echo protocol (runs above the SSL app-transport)."""

    def __init__(self):
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)

    def connection_lost(self, exc):
        pass


class _Collector(asyncio.Protocol):
    """Client-side protocol collecting bytes until connection loss."""

    def __init__(self, loop):
        self.transport = None
        self.data = bytearray()
        self.connected = loop.create_future()
        self.closed = loop.create_future()

    def connection_made(self, transport):
        self.transport = transport
        self.connected.set_result(None)

    def data_received(self, data):
        self.data.extend(data)

    def connection_lost(self, exc):
        if not self.closed.done():
            if exc is None:
                self.closed.set_result(None)
            else:
                self.closed.set_exception(exc)
                # Avoid "exception never retrieved" if a test doesn't await.
                self.closed.exception()


# ---------------------------------------------------------------------------
# echo + payload sizes
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("payload", [b"hello-tls", b"x" * (1024 * 1024 + 17)],
                         ids=["small", "1MB+"])
def test_tls_echo_roundtrip(loop, payload):
    async def main():
        server = await loop.create_server(
            _Echo, "127.0.0.1", 0, ssl=_server_ctx())
        port = server.sockets[0].getsockname()[1]

        cp = _Collector(loop)
        tr, proto = await loop.create_connection(
            lambda: cp, "127.0.0.1", port,
            ssl=_client_ctx(), server_hostname="localhost")
        assert proto is cp
        # The caller gets the SSL app-transport, not the raw TCP transport.
        assert tr.get_extra_info("ssl_object") is not None

        tr.write(payload)
        await asyncio.wait_for(
            _wait_for_len(cp, len(payload)), 30)
        assert bytes(cp.data) == payload

        tr.close()
        await asyncio.wait_for(cp.closed, 10)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 10)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


async def _wait_for_len(cp, n):
    while len(cp.data) < n:
        await asyncio.sleep(0.005)


# ---------------------------------------------------------------------------
# extra_info surface
# ---------------------------------------------------------------------------
def test_tls_get_extra_info(loop):
    async def main():
        client_ctx = _client_ctx()
        server = await loop.create_server(
            _Echo, "127.0.0.1", 0, ssl=_server_ctx())
        port = server.sockets[0].getsockname()[1]

        cp = _Collector(loop)
        tr, _ = await loop.create_connection(
            lambda: cp, "127.0.0.1", port,
            ssl=client_ctx, server_hostname="localhost")

        ssl_obj = tr.get_extra_info("ssl_object")
        assert isinstance(ssl_obj, ssl.SSLObject)
        peercert = tr.get_extra_info("peercert")
        assert peercert, "client must see the server certificate"
        sans = dict.fromkeys(
            v for _k, v in peercert.get("subjectAltName", ()))
        assert "localhost" in sans
        assert tr.get_extra_info("sslcontext") is client_ctx
        # Raw-transport info is forwarded through the SSL app-transport.
        assert tr.get_extra_info("peername")[1] == port

        tr.close()
        await asyncio.wait_for(cp.closed, 10)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 10)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# handshake failure: untrusted server certificate
# ---------------------------------------------------------------------------
def test_tls_handshake_failure_untrusted_cert(loop):
    server_errors = []

    def exc_handler(_loop, context):
        server_errors.append(context.get("exception"))

    async def main():
        app_protos = []

        def factory():
            p = _Echo()
            app_protos.append(p)
            return p

        server = await loop.create_server(
            factory, "127.0.0.1", 0, ssl=_server_ctx())
        port = server.sockets[0].getsockname()[1]

        # Default client context WITHOUT our CA: verification must fail.
        with pytest.raises(ssl.SSLCertVerificationError):
            await asyncio.wait_for(
                loop.create_connection(
                    lambda: _Collector(loop), "127.0.0.1", port,
                    ssl=ssl.create_default_context(),
                    server_hostname="localhost"),
                15)

        # Server side: the handshake failed before the app protocol was
        # connected, so the app protocol never sees the connection and the
        # server keeps serving. (asyncio semantics: SSLProtocol._fatal_error
        # only *debug-logs* OSError-family errors -- ssl.SSLError included --
        # so nothing reaches the loop exception handler; anything that DOES
        # reach it must still be an SSL/OS error, not e.g. an AttributeError
        # from a broken transport/protocol wiring.)
        await asyncio.sleep(0.1)
        for p in app_protos:
            assert p.transport is None, \
                "app protocol must not see a failed-handshake connection"
        for e in server_errors:
            assert e is None or isinstance(e, OSError), server_errors

        # ... and a well-configured client still connects fine afterwards.
        cp = _Collector(loop)
        tr, _ = await loop.create_connection(
            lambda: cp, "127.0.0.1", port,
            ssl=_client_ctx(), server_hostname="localhost")
        tr.write(b"still alive")
        await asyncio.wait_for(_wait_for_len(cp, 11), 10)
        tr.close()
        await asyncio.wait_for(cp.closed, 10)

        server.close()
        await asyncio.wait_for(server.wait_closed(), 10)

    loop.set_exception_handler(exc_handler)
    try:
        loop.run_until_complete(asyncio.wait_for(main(), 60))
    finally:
        loop.set_exception_handler(None)


def test_tls_ssl_true_uses_default_context(loop):
    """ssl=True builds a default (verifying) client context: against our
    self-signed server the handshake must fail verification -- proving the
    default-context path is wired, without needing a public CA."""
    async def main():
        server = await loop.create_server(
            _Echo, "127.0.0.1", 0, ssl=_server_ctx())
        port = server.sockets[0].getsockname()[1]
        with pytest.raises(ssl.SSLCertVerificationError):
            await asyncio.wait_for(
                loop.create_connection(
                    lambda: _Collector(loop), "127.0.0.1", port,
                    ssl=True, server_hostname="localhost"),
                15)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 10)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# flow control under TLS: bulk transfer with drain() must not deadlock
# ---------------------------------------------------------------------------
def test_tls_flow_control_bulk_no_deadlock(loop):
    total = 8 * 1024 * 1024   # 8 MiB each direction
    chunk = 64 * 1024

    async def main():
        async def handle(reader, writer):
            # Echo server: read chunks, write them back, honoring drain().
            try:
                while True:
                    data = await reader.read(chunk)
                    if not data:
                        break
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()

        server = await asyncio.start_server(
            handle, "127.0.0.1", 0, ssl=_server_ctx())
        port = server.sockets[0].getsockname()[1]

        reader, writer = await asyncio.open_connection(
            "127.0.0.1", port, ssl=_client_ctx(),
            server_hostname="localhost")

        async def pump_out():
            sent = 0
            payload = b"\xab" * chunk
            while sent < total:
                writer.write(payload)
                await writer.drain()     # exercises pause/resume_writing
                sent += len(payload)

        async def pump_in():
            got = 0
            while got < total:
                data = await reader.read(chunk)
                assert data, "connection closed early"
                got += len(data)
            return got

        _, got = await asyncio.gather(pump_out(), pump_in())
        assert got == total

        writer.close()
        try:
            await asyncio.wait_for(writer.wait_closed(), 10)
        except (ConnectionError, ssl.SSLError):
            pass
        server.close()
        await asyncio.wait_for(server.wait_closed(), 10)

    loop.run_until_complete(asyncio.wait_for(main(), 120))


# ---------------------------------------------------------------------------
# uvicorn --ssl integration smoke
# ---------------------------------------------------------------------------
def test_uvicorn_tls_smoke(loop):
    uvicorn = pytest.importorskip("uvicorn")
    httpx = pytest.importorskip("httpx")

    async def app(scope, receive, send):
        assert scope["type"] == "http"
        assert scope["scheme"] == "https"
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"hello-tls"})

    async def main():
        port = _free_port()
        config = uvicorn.Config(
            app,
            host="127.0.0.1",
            port=port,
            lifespan="off",
            log_level="warning",
            ssl_certfile=SERVER_CERT,
            ssl_keyfile=SERVER_KEY,
        )
        server = uvicorn.Server(config)
        task = asyncio.get_running_loop().create_task(server.serve())
        try:
            deadline = loop.time() + 15.0
            while not server.started:
                if task.done():
                    task.result()
                    raise RuntimeError("uvicorn ended before startup")
                if loop.time() > deadline:
                    raise TimeoutError("uvicorn did not start within 15s")
                await asyncio.sleep(0.01)

            client_ctx = _client_ctx()
            async with httpx.AsyncClient(verify=client_ctx) as client:
                r = await client.get(f"https://localhost:{port}/")
                assert r.status_code == 200
                assert r.text == "hello-tls"
        finally:
            server.should_exit = True
            try:
                await asyncio.wait_for(asyncio.shield(task), 15)
            except asyncio.TimeoutError:
                task.cancel()

    loop.run_until_complete(asyncio.wait_for(main(), 60))


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# version-gated parameter surface
# ---------------------------------------------------------------------------
def test_ssl_shutdown_timeout_gate(loop):
    async def main():
        if sys.version_info >= (3, 11):
            # Accepted (passed through to sslproto) -- pair it with a real
            # handshake so the parameter reaches SSLProtocol.
            server = await loop.create_server(
                _Echo, "127.0.0.1", 0, ssl=_server_ctx(),
                ssl_shutdown_timeout=5.0)
            port = server.sockets[0].getsockname()[1]
            cp = _Collector(loop)
            tr, _ = await loop.create_connection(
                lambda: cp, "127.0.0.1", port,
                ssl=_client_ctx(), server_hostname="localhost",
                ssl_shutdown_timeout=5.0)
            tr.close()
            await asyncio.wait_for(cp.closed, 10)
            server.close()
            await asyncio.wait_for(server.wait_closed(), 10)
        else:
            # 3.10: pre-3.11 sslproto has no ssl_shutdown_timeout.
            with pytest.raises(TypeError):
                await loop.create_server(
                    _Echo, "127.0.0.1", 0, ssl=_server_ctx(),
                    ssl_shutdown_timeout=5.0)

    loop.run_until_complete(asyncio.wait_for(main(), 30))
