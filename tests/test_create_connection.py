# coding:utf-8
import time
import unittest
import threading
import select
import socket
import asyncio
from hvloop import new_event_loop
# from asyncio import new_event_loop


class EchoProtocol(asyncio.Protocol):

    def connection_made(self, transport) -> None:
        super().connection_made(transport)
        assert transport.get_extra_info('sockname') is not None
        assert transport.get_extra_info('peername') is not None
        self.transport = transport
        self.future = None

    def data_received(self, data: bytes) -> None:
        super().data_received(data)
        if self.future:
            self.future.set_result(data)

    def eof_received(self):
        return super().eof_received()

    async def get_echo(self, data, waiter):
        self.future = waiter
        self.transport.write(data)
        return await waiter


class OnceEchoServer(threading.Thread):
    def __init__(self, addr, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.addr = addr
        self.s = socket.create_server(self.addr, family=socket.AF_INET, backlog=1)

    def run(self):
        client, _ = self.s.accept()
        data = client.recv(4096)
        client.sendall(data)
        client.close()
        self.s.close()


class TestCreateConnection(unittest.TestCase):

    def setUp(self):
        self.addr = ('127.0.0.1', 50001)
        self.server = OnceEchoServer(self.addr)
        self.server.start()

    def test_connection(self):
        loop = new_event_loop()

        msg = b"hello world"

        async def send_to_echo(data):
            transport, protocol = await loop.create_connection(
                EchoProtocol, host=self.addr[0], port=self.addr[1]
            )
            waiter = loop.create_future()
            return await protocol.get_echo(data, waiter)

        resp = loop.run_until_complete(send_to_echo(msg))
        assert resp == msg

    def test_connection_with_sock(self):
        sock = socket.socket(family=socket.AF_INET, type=socket.SOCK_STREAM)
        sock.setblocking(False)
        try:
            sock.connect(self.addr)
        except BlockingIOError:
            _, wlist, _ = select.select([], [sock.fileno()], [])
        err = sock.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if err != 0:
            raise OSError(err, f"Connect call failed {self.addr}")
        loop = new_event_loop()

        msg = b"hello world"

        async def send_to_echo(data):
            transport, protocol = await loop.create_connection(
                EchoProtocol, sock=sock
            )
            waiter = loop.create_future()
            return await protocol.get_echo(data, waiter)

        resp = loop.run_until_complete(send_to_echo(msg))
        assert resp == msg
