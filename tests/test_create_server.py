import asyncio
import time
from asyncio import transports
from typing import Optional
import unittest
import threading
import socket
from hvloop import new_event_loop
# from asyncio import new_event_loop


class EchoServerProtocol(asyncio.Protocol):
    def connection_made(self, transport: transports.BaseTransport) -> None:
        peername = transport.get_extra_info('peername')
        print("connection from {}".format(peername))
        self.transport = transport

    def data_received(self, data: bytes) -> None:
        self.transport.write(data)
        self.transport.close()

    def eof_received(self) -> Optional[bool]:
        pass

    def connection_lost(self, exc: Optional[Exception]) -> None:
        pass


class TestCreateServer(unittest.TestCase):

    def test_create_server(self):
        loop = new_event_loop()
        self.address = ('127.0.0.1', 50002)
        lock = threading.Lock()

        server = None

        async def _server():
            nonlocal server
            server = await loop.create_server(EchoServerProtocol, self.address[0], self.address[1], start_serving=False)
            await server.start_serving()
            lock.release()
            await server.serve_forever()

        def _run():
            try:
                loop.run_until_complete(_server())
            except asyncio.exceptions.CancelledError:
                pass
        # loop.run_until_complete(_server())

        lock.acquire()
        threading.Thread(target=_run, daemon=True).start()

        lock.acquire()
        s = socket.socket(family=socket.AF_INET)
        s.settimeout(3)
        s.connect(self.address)
        msg = b"hello world"
        s.sendall(msg)
        #
        received = s.recv(4096)
        s.close()
        assert msg == received
        def _close_server():
            nonlocal server
            server.close()

        # loop.call_soon_threadsafe(_close_server)

