"""M4 sock_* tests (tech design section 5, Phase 2).

sock_recv / sock_recv_into / sock_sendall / sock_connect / sock_accept are
built on the M2b add_reader/add_writer machinery with asyncio *selector*
event loop semantics: non-blocking sockets (validated in debug mode), fds
stay caller-owned, one temporary reader/writer per pending operation.

Constraint (documented in the implementation, same as asyncio): a socket
used with sock_* must not simultaneously be owned by a transport of the
same loop or carry a user add_reader/add_writer registration in the same
direction.
"""

import asyncio
import socket
import ssl

import pytest


def _nonblocking_socketpair():
    a, b = socket.socketpair()
    a.setblocking(False)
    b.setblocking(False)
    return a, b


# ---------------------------------------------------------------------------
# sock_recv / sock_sendall round trip on a socketpair
# ---------------------------------------------------------------------------
def test_sock_recv_sendall_roundtrip(loop):
    a, b = _nonblocking_socketpair()

    async def main():
        # Data already pending: sock_recv completes on the fast path.
        await loop.sock_sendall(a, b"ping")
        assert await asyncio.wait_for(loop.sock_recv(b, 100), 10) == b"ping"

        # No data pending: sock_recv must wait for readiness.
        recv_task = loop.create_task(loop.sock_recv(a, 100))
        await asyncio.sleep(0.05)
        assert not recv_task.done()
        await loop.sock_sendall(b, b"pong")
        assert await asyncio.wait_for(recv_task, 10) == b"pong"

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        a.close()
        b.close()


def test_sock_sendall_large_payload(loop):
    # Big enough to overflow the kernel socket buffer -> forces the
    # add_writer retry path inside sock_sendall.
    payload = b"\xcd" * (4 * 1024 * 1024)
    a, b = _nonblocking_socketpair()

    async def main():
        async def drain():
            got = bytearray()
            while len(got) < len(payload):
                chunk = await loop.sock_recv(b, 256 * 1024)
                assert chunk, "peer closed early"
                got.extend(chunk)
            return bytes(got)

        send_task = loop.create_task(loop.sock_sendall(a, payload))
        got = await asyncio.wait_for(drain(), 60)
        await asyncio.wait_for(send_task, 10)
        assert got == payload

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 90))
    finally:
        a.close()
        b.close()


def test_sock_recv_into(loop):
    a, b = _nonblocking_socketpair()

    async def main():
        await loop.sock_sendall(a, b"buffer-me")
        buf = bytearray(64)
        n = await asyncio.wait_for(loop.sock_recv_into(b, buf), 10)
        assert n == 9
        assert bytes(buf[:n]) == b"buffer-me"

        # Blocking path: no data yet.
        buf2 = bytearray(16)
        task = loop.create_task(loop.sock_recv_into(a, buf2))
        await asyncio.sleep(0.05)
        assert not task.done()
        await loop.sock_sendall(b, b"later")
        n2 = await asyncio.wait_for(task, 10)
        assert bytes(buf2[:n2]) == b"later"

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        a.close()
        b.close()


def test_sock_recv_eof_returns_empty(loop):
    a, b = _nonblocking_socketpair()

    async def main():
        task = loop.create_task(loop.sock_recv(b, 100))
        await asyncio.sleep(0.02)
        a.close()
        assert await asyncio.wait_for(task, 10) == b""

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        b.close()


# ---------------------------------------------------------------------------
# sock_connect + sock_accept build a connection
# ---------------------------------------------------------------------------
def test_sock_connect_accept(loop):
    lsock = socket.socket()
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(8)
    lsock.setblocking(False)
    port = lsock.getsockname()[1]

    csock = socket.socket()
    csock.setblocking(False)

    conn_holder = []

    async def main():
        accept_task = loop.create_task(loop.sock_accept(lsock))
        await loop.sock_connect(csock, ("127.0.0.1", port))
        conn, addr = await asyncio.wait_for(accept_task, 10)
        conn_holder.append(conn)
        assert conn.gettimeout() == 0  # accepted socket is non-blocking
        assert addr[0] == "127.0.0.1"

        # And the pair actually works with sock_sendall/sock_recv.
        await loop.sock_sendall(csock, b"over-accept")
        assert await asyncio.wait_for(
            loop.sock_recv(conn, 100), 10) == b"over-accept"

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        for s in (lsock, csock, *conn_holder):
            s.close()


def test_sock_connect_refused(loop):
    # Grab a port that is certainly closed.
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()

    csock = socket.socket()
    csock.setblocking(False)

    async def main():
        with pytest.raises(ConnectionRefusedError):
            await asyncio.wait_for(
                loop.sock_connect(csock, ("127.0.0.1", port)), 10)

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        csock.close()


def test_sock_connect_resolves_hostname(loop):
    lsock = socket.socket()
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(1)
    lsock.setblocking(False)
    port = lsock.getsockname()[1]

    csock = socket.socket()
    csock.setblocking(False)

    async def main():
        accept_task = loop.create_task(loop.sock_accept(lsock))
        # Hostname (not numeric) exercises the getaddrinfo path.
        await loop.sock_connect(csock, ("localhost", port))
        conn, _ = await asyncio.wait_for(accept_task, 10)
        conn.close()

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        lsock.close()
        csock.close()


# ---------------------------------------------------------------------------
# validation, asyncio-conformant
# ---------------------------------------------------------------------------
def test_sock_blocking_socket_rejected_in_debug(loop):
    a, b = socket.socketpair()   # blocking

    async def main():
        with pytest.raises(ValueError):
            await loop.sock_recv(a, 10)
        with pytest.raises(ValueError):
            await loop.sock_recv_into(a, bytearray(4))
        with pytest.raises(ValueError):
            await loop.sock_sendall(a, b"x")
        with pytest.raises(ValueError):
            await loop.sock_connect(a, ("127.0.0.1", 1))
        with pytest.raises(ValueError):
            await loop.sock_accept(a)

    loop.set_debug(True)
    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        loop.set_debug(False)
        a.close()
        b.close()


def test_sock_sslsocket_rejected(loop):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.socket()
    wrapped = ctx.wrap_socket(raw, do_handshake_on_connect=False)

    async def main():
        with pytest.raises(TypeError):
            await loop.sock_recv(wrapped, 10)
        with pytest.raises(TypeError):
            await loop.sock_sendall(wrapped, b"x")
        with pytest.raises(TypeError):
            await loop.sock_connect(wrapped, ("127.0.0.1", 1))
        with pytest.raises(TypeError):
            await loop.sock_accept(wrapped)

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        wrapped.close()


def test_sock_recv_cancellation_releases_reader(loop):
    # Cancelling a pending sock_recv must remove the temporary reader so the
    # fd is immediately reusable with add_reader (M2b machinery underneath).
    a, b = _nonblocking_socketpair()

    async def main():
        task = loop.create_task(loop.sock_recv(b, 100))
        await asyncio.sleep(0.02)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        # The reader slot is free again: a plain add_reader works and fires.
        fired = loop.create_future()
        loop.add_reader(b, lambda: not fired.done() and
                        fired.set_result(None))
        a.send(b"x")
        await asyncio.wait_for(fired, 10)
        assert loop.remove_reader(b) is True

    try:
        loop.run_until_complete(asyncio.wait_for(main(), 30))
    finally:
        a.close()
        b.close()
