"""M2a tests: TCPTransport, create_connection, create_server, Server.

Plan section 12.2: echo client/server, large payloads, read pause/resume,
write watermarks (pause_writing/resume_writing), peer close -> connection_lost,
abort, the create_server(sock=...) fd-ownership path, asyncio streams smoke
(the real path DB drivers use), idle-CPU regression guard, and loop.close()
with still-open transports/servers.

Same style as the M1 suite: synchronous tests that construct their own loop
(``loop`` fixture) and drive coroutines via run_until_complete.
"""

import asyncio
import importlib.util
import os
import socket
import sys
import time

import pytest

import hvloop


# ---------------------------------------------------------------------------
# Helper protocols
# ---------------------------------------------------------------------------
class Recorder(asyncio.Protocol):
    """Records everything; exposes futures for connect/close."""

    def __init__(self, loop):
        self.loop = loop
        self.transport = None
        self.data = bytearray()
        self.eof = False
        self.pauses = 0
        self.resumes = 0
        self.connected = loop.create_future()
        self.closed = loop.create_future()

    def connection_made(self, transport):
        self.transport = transport
        if not self.connected.done():
            self.connected.set_result(None)

    def data_received(self, data):
        self.data.extend(data)

    def eof_received(self):
        self.eof = True
        return False

    def pause_writing(self):
        self.pauses += 1

    def resume_writing(self):
        self.resumes += 1

    def connection_lost(self, exc):
        if not self.closed.done():
            self.closed.set_result(exc)


class EchoRecorder(Recorder):
    def data_received(self, data):
        super().data_received(data)
        self.transport.write(data)


async def _poll_until(cond, timeout=10.0, interval=0.005):
    deadline = time.monotonic() + timeout
    while not cond():
        if time.monotonic() > deadline:
            raise TimeoutError("condition not met within {}s".format(timeout))
        await asyncio.sleep(interval)


async def _make_echo_server(loop, protos, **kwargs):
    def factory():
        p = EchoRecorder(loop)
        protos.append(p)
        return p

    server = await loop.create_server(factory, "127.0.0.1", 0, **kwargs)
    port = server.sockets[0].getsockname()[1]
    return server, port


# ---------------------------------------------------------------------------
# Echo roundtrip & basic transport API
# ---------------------------------------------------------------------------
def test_echo_roundtrip(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        assert server.is_serving()

        cp = Recorder(loop)
        tr, proto = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        assert proto is cp
        await asyncio.wait_for(cp.connected, 5)

        payload = b"hello hvloop " * 64
        tr.write(payload)
        await _poll_until(lambda: len(cp.data) >= len(payload))
        assert bytes(cp.data) == payload

        # extra_info: sockname/peername are required (uvicorn depends on them)
        assert tr.get_extra_info("peername") == ("127.0.0.1", port)
        sockname = tr.get_extra_info("sockname")
        assert sockname[0] == "127.0.0.1"
        # 'socket' is a dup()-based real socket object
        sob = tr.get_extra_info("socket")
        assert sob is not None
        assert sob.getsockname() == sockname
        assert tr.get_extra_info("nonexistent", "fallback") == "fallback"

        assert tr.can_write_eof() is True
        assert tr.is_reading() is True
        assert not tr.is_closing()
        assert tr.get_protocol() is cp

        tr.close()
        assert tr.is_closing()
        assert (await asyncio.wait_for(cp.closed, 5)) is None
        # server side observes the disconnect as well
        assert (await asyncio.wait_for(server_protos[0].closed, 5)) is None

        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)
        assert not server.is_serving()
        assert server.sockets == ()

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_large_payload_roundtrip(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        payload = os.urandom(1024) * 1500  # ~1.5 MiB, non-trivial content
        tr.write(payload)
        await _poll_until(lambda: len(cp.data) >= len(payload), timeout=20)
        assert bytes(cp.data) == payload

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


def test_writelines_and_write_validation(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        with pytest.raises(TypeError):
            tr.write("not bytes")
        tr.write(b"")  # no-op
        tr.writelines([b"a", bytearray(b"b"), memoryview(b"c")])
        await _poll_until(lambda: len(cp.data) >= 3)
        assert bytes(cp.data) == b"abc"

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# pause_reading / resume_reading
# ---------------------------------------------------------------------------
def test_pause_resume_reading(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        # Wait for the server-side transport, then pause its reading.
        await _poll_until(lambda: len(server_protos) == 1)
        sp = server_protos[0]
        await asyncio.wait_for(sp.connected, 5)
        sp.transport.pause_reading()
        assert not sp.transport.is_reading()
        sp.transport.pause_reading()  # idempotent, no error

        tr.write(b"x" * 1024)
        # While paused the server protocol must receive nothing.
        await asyncio.sleep(0.2)
        assert len(sp.data) == 0

        sp.transport.resume_reading()
        assert sp.transport.is_reading()
        sp.transport.resume_reading()  # idempotent, no error
        await _poll_until(lambda: len(sp.data) == 1024)
        # echo comes back to the client
        await _poll_until(lambda: len(cp.data) == 1024)

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# Write flow control: pause_writing / resume_writing
# ---------------------------------------------------------------------------
@pytest.mark.xfail(
    sys.platform == "win32",
    reason="Windows write-buffer backpressure differs: an 8 MiB write to a "
    "paused peer is absorbed by the larger default loopback socket buffers "
    "(and/or libhv's Windows write-queue accounting), so hio_write_bufsize "
    "stays 0 and pause_writing never fires. Unverified on real hardware; "
    "tracked as a known Windows limitation (see CLAUDE.md).",
    strict=False,
)
def test_write_flow_control(loop):
    class PausingServer(Recorder):
        def connection_made(self, transport):
            transport.pause_reading()  # build backpressure
            super().connection_made(transport)

    async def main():
        server_protos = []

        def factory():
            p = PausingServer(loop)
            server_protos.append(p)
            return p

        server = await loop.create_server(factory, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        tr.set_write_buffer_limits(high=16 * 1024, low=4 * 1024)
        assert tr.get_write_buffer_limits() == (4 * 1024, 16 * 1024)

        payload = b"x" * (8 * 1024 * 1024)  # far beyond kernel buffers
        tr.write(payload)
        # The unsent remainder sits in libhv's write queue: over high water,
        # pause_writing must have been delivered synchronously.
        assert cp.pauses == 1
        assert tr.get_write_buffer_size() > 0

        # Un-pause the peer; everything drains and resume_writing fires.
        await _poll_until(lambda: len(server_protos) == 1)
        await asyncio.wait_for(server_protos[0].connected, 5)
        server_protos[0].transport.resume_reading()
        await _poll_until(lambda: cp.resumes >= 1, timeout=30)
        assert cp.pauses == 1
        await _poll_until(
            lambda: len(server_protos[0].data) == len(payload), timeout=30
        )
        assert tr.get_write_buffer_size() == 0

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


def test_set_write_buffer_limits_validation(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        with pytest.raises(ValueError):
            tr.set_write_buffer_limits(high=10, low=20)
        tr.set_write_buffer_limits(low=256)
        assert tr.get_write_buffer_limits() == (256, 1024)
        tr.set_write_buffer_limits()
        assert tr.get_write_buffer_limits() == (16 * 1024, 64 * 1024)
        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# Peer close -> eof_received + connection_lost
# ---------------------------------------------------------------------------
def test_peer_close_triggers_eof_and_connection_lost(loop):
    class CloseOnConnect(Recorder):
        def connection_made(self, transport):
            super().connection_made(transport)
            transport.close()

    async def main():
        server_protos = []

        def factory():
            p = CloseOnConnect(loop)
            server_protos.append(p)
            return p

        server = await loop.create_server(factory, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        # Client sees the peer's clean shutdown: best-effort eof_received,
        # then connection_lost(None). (libhv closes on EOF, so eof_received
        # returning True can't keep the connection open -- documented
        # deviation, plan section 6.)
        exc = await asyncio.wait_for(cp.closed, 5)
        assert exc is None
        assert cp.eof is True
        assert tr.is_closing()

        # server side got its own connection_lost(None) via close()
        assert (await asyncio.wait_for(server_protos[0].closed, 5)) is None

        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


@pytest.mark.xfail(
    sys.platform == "win32",
    reason="Depends on a large write staying queued (get_write_buffer_size() > "
    "0) right after write(); on Windows the payload is absorbed by loopback "
    "socket buffers so the buffer reads 0. The flush-on-close behaviour itself "
    "is fine; only the synchronous buffered-size assertion doesn't hold. "
    "Unverified on real hardware; known Windows limitation (see CLAUDE.md).",
    strict=False,
)
def test_close_flushes_pending_writes(loop):
    # libhv's hio_close defers the actual close until the write queue is
    # flushed; close() immediately after a large write must not truncate.
    async def main():
        server_protos = []

        def factory():
            p = Recorder(loop)
            server_protos.append(p)
            return p

        server = await loop.create_server(factory, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        payload = b"y" * (4 * 1024 * 1024)
        tr.write(payload)
        # close() while a good chunk of payload is still in libhv's queue
        assert tr.get_write_buffer_size() > 0
        tr.close()

        await _poll_until(lambda: len(server_protos) == 1)
        sp = server_protos[0]
        await _poll_until(lambda: len(sp.data) == len(payload), timeout=30)
        assert bytes(sp.data) == payload

        assert (await asyncio.wait_for(cp.closed, 10)) is None
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


# ---------------------------------------------------------------------------
# abort
# ---------------------------------------------------------------------------
def test_abort(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)

        tr.write(b"z" * (4 * 1024 * 1024))
        tr.abort()  # immediate close, pending buffer discarded
        assert tr.is_closing()
        # asyncio semantics: abort() reports connection_lost(None)
        assert (await asyncio.wait_for(cp.closed, 5)) is None

        # the server side observes the connection going away (clean EOF or
        # ECONNRESET depending on timing)
        await _poll_until(lambda: len(server_protos) == 0 or
                          server_protos[0].closed.done(), timeout=10)

        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# write_eof
# ---------------------------------------------------------------------------
def test_write_eof(loop):
    async def main():
        server_protos = []

        def factory():
            p = Recorder(loop)
            server_protos.append(p)
            return p

        server = await loop.create_server(factory, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        assert tr.can_write_eof() is True

        payload = b"w" * (2 * 1024 * 1024)
        tr.write(payload)
        tr.write_eof()  # SHUT_WR once the libhv write buffer drains
        with pytest.raises(RuntimeError):
            tr.write(b"after eof")

        sp = None
        await _poll_until(lambda: len(server_protos) == 1)
        sp = server_protos[0]
        # The server receives the complete payload and then the EOF.
        await _poll_until(lambda: len(sp.data) == len(payload), timeout=30)
        assert bytes(sp.data) == payload
        assert (await asyncio.wait_for(sp.closed, 10)) is None
        assert sp.eof is True

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


# ---------------------------------------------------------------------------
# create_connection error paths
# ---------------------------------------------------------------------------
def test_create_connection_refused(loop):
    async def main():
        # Grab a port that is definitely not listening.
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()

        with pytest.raises(ConnectionRefusedError):
            await asyncio.wait_for(
                loop.create_connection(lambda: Recorder(loop),
                                       "127.0.0.1", port),
                10,
            )

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_create_connection_arg_validation(loop):
    async def main():
        # TLS-related validation (asyncio semantics; M4 -- TLS is supported,
        # the ssl-vs-server_hostname/timeout combinations must be checked).
        with pytest.raises(ValueError):
            await loop.create_connection(lambda: Recorder(loop),
                                         "127.0.0.1", 80,
                                         server_hostname="x")  # no ssl
        with pytest.raises(ValueError):
            await loop.create_connection(lambda: Recorder(loop),
                                         "127.0.0.1", 80,
                                         ssl_handshake_timeout=1.0)  # no ssl
        with pytest.raises(ValueError):
            # ssl with sock= (no host) requires an explicit server_hostname.
            sock = socket.socket()
            try:
                await loop.create_connection(
                    lambda: Recorder(loop), sock=sock, ssl=True)
            finally:
                sock.close()
        with pytest.raises(ValueError):
            await loop.create_connection(lambda: Recorder(loop))
        with pytest.raises(ValueError):
            sock = socket.socket()
            try:
                await loop.create_connection(
                    lambda: Recorder(loop), "127.0.0.1", 80, sock=sock)
            finally:
                sock.close()

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_create_connection_with_sock(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)

        # Pre-connected socket handed to create_connection: the transport
        # takes ownership (asyncio semantics).
        raw = socket.create_connection(("127.0.0.1", port))
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, sock=raw)
        assert raw.fileno() == -1  # detached: libhv owns the fd now

        tr.write(b"via sock=")
        await _poll_until(lambda: len(cp.data) == 9)
        assert bytes(cp.data) == b"via sock="

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# create_server variations
# ---------------------------------------------------------------------------
def test_create_server_external_sock_fd_ownership(loop):
    # plan section 7: an externally provided socket's fd belongs to the
    # caller; server.close() must not close it.
    async def main():
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]

        server_protos = []

        def factory():
            p = EchoRecorder(loop)
            server_protos.append(p)
            return p

        server = await loop.create_server(factory, sock=sock)
        assert server.sockets[0] is sock

        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        tr.write(b"ext")
        await _poll_until(lambda: len(cp.data) == 3)
        tr.close()
        await asyncio.wait_for(cp.closed, 5)

        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

        # The caller's fd is still alive and well after server.close().
        assert sock.fileno() != -1
        sock.getsockname()  # raises if the fd were closed (portable; os.fstat fails on Windows sockets)
        sock.close()  # and the caller can close it normally

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_create_server_start_serving_false(loop):
    async def main():
        protos = []

        def factory():
            p = EchoRecorder(loop)
            protos.append(p)
            return p

        server = await loop.create_server(
            factory, "127.0.0.1", 0, start_serving=False)
        assert not server.is_serving()
        port = server.sockets[0].getsockname()[1]

        # No accept processing before start_serving: the connection sits in
        # the backlog and no protocol is created.
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        await asyncio.sleep(0.2)
        assert protos == []

        await server.start_serving()
        assert server.is_serving()
        await _poll_until(lambda: len(protos) == 1)

        tr.write(b"go")
        await _poll_until(lambda: len(cp.data) == 2)

        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_create_server_validation(loop):
    async def main():
        with pytest.raises(TypeError):
            # asyncio semantics: create_server(ssl=...) takes an SSLContext
            # or None, never a bool.
            await loop.create_server(lambda: None, "127.0.0.1", 0, ssl=True)
        with pytest.raises(ValueError):
            await loop.create_server(lambda: None, "127.0.0.1", 0,
                                     ssl_handshake_timeout=1.0)  # no ssl
        with pytest.raises(ValueError):
            await loop.create_server(lambda: None)
        with pytest.raises(ValueError):
            sock = socket.socket()
            try:
                await loop.create_server(
                    lambda: None, "127.0.0.1", 0, sock=sock)
            finally:
                sock.close()

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_server_async_context_manager_and_serve_forever(loop):
    async def main():
        protos = []

        def factory():
            p = EchoRecorder(loop)
            protos.append(p)
            return p

        async with await loop.create_server(
                factory, "127.0.0.1", 0, start_serving=False) as server:
            task = loop.create_task(server.serve_forever())
            await asyncio.sleep(0.05)
            assert server.is_serving()
            port = server.sockets[0].getsockname()[1]

            cp = Recorder(loop)
            tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
            tr.write(b"sf")
            await _poll_until(lambda: len(cp.data) == 2)
            tr.close()
            await asyncio.wait_for(cp.closed, 5)

            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        assert not server.is_serving()

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_wait_closed_waits_for_connections(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        await _poll_until(lambda: len(server_protos) == 1)
        await asyncio.wait_for(server_protos[0].connected, 5)

        server.close()
        waiter = loop.create_task(server.wait_closed())
        await asyncio.sleep(0.1)
        # the accepted connection is still open -> wait_closed still pending
        assert not waiter.done()

        tr.close()
        await asyncio.wait_for(waiter, 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


# ---------------------------------------------------------------------------
# asyncio streams smoke test (the real path DB drivers / clients use)
# ---------------------------------------------------------------------------
def test_asyncio_streams_echo(loop):
    async def handler(reader, writer):
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
        writer.close()

    async def main():
        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]

        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        payload = os.urandom(256 * 1024)
        writer.write(payload)
        await writer.drain()
        echoed = await asyncio.wait_for(reader.readexactly(len(payload)), 20)
        assert echoed == payload

        peer = writer.get_extra_info("peername")
        assert peer == ("127.0.0.1", port)

        writer.close()
        await asyncio.wait_for(writer.wait_closed(), 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))


# ---------------------------------------------------------------------------
# Idle CPU guard: a listening server must not busy-poll
# ---------------------------------------------------------------------------
@pytest.mark.skipif(
    importlib.util.find_spec("resource") is None,
    reason="resource.getrusage not available on this platform (e.g. Windows)",
)
def test_idle_server_does_not_burn_cpu(loop):
    import resource

    async def main():
        server = await loop.create_server(
            lambda: EchoRecorder(loop), "127.0.0.1", 0)

        u0 = resource.getrusage(resource.RUSAGE_SELF)
        cpu0 = u0.ru_utime + u0.ru_stime
        await asyncio.sleep(1.0)
        u1 = resource.getrusage(resource.RUSAGE_SELF)
        cpu1 = u1.ru_utime + u1.ru_stime

        server.close()
        await server.wait_closed()
        return cpu1 - cpu0

    cpu_used = loop.run_until_complete(asyncio.wait_for(main(), 30))
    assert cpu_used < 0.3, "idle server burned {:.3f}s CPU".format(cpu_used)


# ---------------------------------------------------------------------------
# loop.close() with still-open transports / servers
# ---------------------------------------------------------------------------
def test_loop_close_with_open_transport_and_server():
    lp = hvloop.new_event_loop()
    state = {}

    async def main():
        server_protos = []

        def factory():
            p = EchoRecorder(lp)
            server_protos.append(p)
            return p

        server = await lp.create_server(factory, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        cp = Recorder(lp)
        tr, _ = await lp.create_connection(lambda: cp, "127.0.0.1", port)
        tr.write(b"live")
        await _poll_until(lambda: len(cp.data) == 4)
        state["server"] = server
        state["tr"] = tr
        state["server_tr"] = server_protos[0].transport

    lp.run_until_complete(asyncio.wait_for(main(), 30))

    # Deliberately leave the server, the client transport and the accepted
    # server-side transport open across loop.close().
    lp.close()
    assert lp.is_closed()

    tr = state["tr"]
    server = state["server"]
    server_tr = state["server_tr"]

    # Post-close: every method must be a safe no-op / sane value, and must
    # not touch freed libhv structures.
    assert tr.is_closing()
    assert not tr.is_reading()
    tr.write(b"after close")  # swallowed (conn_lost accounting)
    tr.pause_reading()
    tr.resume_reading()
    tr.write_eof()
    tr.close()
    tr.abort()
    assert tr.get_write_buffer_size() == 0
    assert tr.get_extra_info("socket") is None
    # cached before close, still available
    assert tr.get_extra_info("peername") is not None

    server_tr.close()
    server_tr.abort()

    server.close()  # listener already torn down by loop.close(); safe
    assert server.sockets == ()

    # And a fresh loop still works afterwards.
    lp2 = hvloop.new_event_loop()
    try:
        assert lp2.run_until_complete(asyncio.sleep(0, result=42)) == 42
    finally:
        lp2.close()


def test_external_sock_survives_loop_close():
    # Variant of fd ownership: loop.close() (not server.close()) must also
    # leave a caller-owned listen socket open.
    lp = hvloop.new_event_loop()
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))

    async def main():
        return await lp.create_server(lambda: EchoRecorder(lp), sock=sock)

    server = lp.run_until_complete(main())
    assert server.is_serving()
    lp.close()

    assert sock.fileno() != -1
    sock.getsockname()  # portable "still open" check (os.fstat fails on Windows sockets)
    sock.close()


# ---------------------------------------------------------------------------
# Misc transport behaviour
# ---------------------------------------------------------------------------
def test_set_get_protocol(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)
        cp = Recorder(loop)
        tr, _ = await loop.create_connection(lambda: cp, "127.0.0.1", port)
        assert tr.get_protocol() is cp
        cp2 = Recorder(loop)
        tr.set_protocol(cp2)
        assert tr.get_protocol() is cp2
        tr.set_protocol(cp)
        tr.close()
        await asyncio.wait_for(cp.closed, 5)
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 30))


def test_multiple_concurrent_connections(loop):
    async def main():
        server_protos = []
        server, port = await _make_echo_server(loop, server_protos)

        clients = []
        for i in range(10):
            cp = Recorder(loop)
            tr, _ = await loop.create_connection(
                lambda cp=cp: cp, "127.0.0.1", port)
            clients.append((tr, cp, b"client-%d" % i))

        for tr, cp, payload in clients:
            tr.write(payload)
        for tr, cp, payload in clients:
            await _poll_until(
                lambda cp=cp, payload=payload: len(cp.data) == len(payload))
            assert bytes(cp.data) == payload

        for tr, cp, _ in clients:
            tr.close()
        for tr, cp, _ in clients:
            await asyncio.wait_for(cp.closed, 5)

        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)

    loop.run_until_complete(asyncio.wait_for(main(), 60))
