import asyncio
import time
from asyncio import transports
from typing import Optional
import unittest
import threading
import socket
from hvloop import new_event_loop
# from asyncio import new_event_loop


class EchoServerProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport: transports.BaseTransport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr) -> None:
        print("server received: %s, from: %s" % (data, addr))
        self.transport.sendto(data, addr)
        self.transport.close()


class EchoClientProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport: transports.BaseTransport) -> None:
        self.transport = transport
        self.waiter = None

    def datagram_received(self, data: bytes, addr) -> None:
        print("recv: %s from <%s>" % (data, addr))
        if self.waiter:
            self.waiter.set_result(data)

    def send(self, data):
        self.transport.sendto(data)
        self.transport.close()

    async def echo(self, data, waiter):
        self.waiter = waiter
        self.transport.sendto(data)
        msg = await self.waiter
        self.transport.close()
        return msg


class TestCreateDatagramEndpoint(unittest.TestCase):

    def test_create_datagram_endpoint(self):
        loop = new_event_loop()
        self.address = ('127.0.0.1', 52002)

        async def _test_echo():
            await loop.create_datagram_endpoint(
                EchoServerProtocol, local_addr=self.address)

            _, proto = await loop.create_datagram_endpoint(
                EchoClientProtocol, remote_addr=self.address
            )
            msg = b'hello world'
            waiter = loop.create_future()
            recv_msg = await proto.echo(msg, waiter)
            assert msg == recv_msg

        loop.run_until_complete(_test_echo())
