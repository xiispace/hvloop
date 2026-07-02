#!/usr/bin/env python3
"""TCP echo throughput: hvloop vs asyncio (vs uvloop when installed).

Methodology (tech design section 12.4)
--------------------------------------
For each event loop implementation, ONE fresh loop runs both an echo server
(``loop.create_server``) and N concurrent client connections
(``loop.create_connection``) over real TCP on 127.0.0.1. Every client
performs R sequential round trips of an S-byte message (a write, then read
until S bytes came back), so one run moves N*R*S bytes each way. Server and
clients sharing a loop measures the *loop's* protocol/transport hot path
(read/write dispatch, flow control bookkeeping), not the kernel; all
implementations are measured under identical conditions.

Usage:
    python benchmarks/bench_tcp_echo.py [--connections 100] [--size 10240]
                                        [--rounds 50] [--repeat 3]
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import platform
import sys
import time


# ---------------------------------------------------------------------------
# protocols
# ---------------------------------------------------------------------------
class EchoServerProtocol(asyncio.Protocol):
    def connection_made(self, transport):
        self.transport = transport

    def data_received(self, data):
        self.transport.write(data)


class EchoClientProtocol(asyncio.Protocol):
    def __init__(self, loop, payload: bytes, rounds: int):
        self.payload = payload
        self.size = len(payload)
        self.rounds = rounds
        self.received = 0
        self.done = loop.create_future()

    def connection_made(self, transport):
        self.transport = transport
        transport.write(self.payload)

    def data_received(self, data):
        self.received += len(data)
        if self.received >= self.size:
            self.received -= self.size
            self.rounds -= 1
            if self.rounds <= 0:
                if not self.done.done():
                    self.done.set_result(None)
                self.transport.close()
            else:
                self.transport.write(self.payload)

    def connection_lost(self, exc):
        if not self.done.done():
            self.done.set_exception(
                exc or ConnectionError("connection lost early"))


# ---------------------------------------------------------------------------
# one benchmark run
# ---------------------------------------------------------------------------
async def _run(loop, connections: int, size: int, rounds: int) -> float:
    payload = b"\x55" * size
    server = await loop.create_server(EchoServerProtocol, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]

    clients = []
    t0 = time.perf_counter()
    for _ in range(connections):
        proto = EchoClientProtocol(loop, payload, rounds)
        await loop.create_connection(lambda p=proto: p, "127.0.0.1", port)
        clients.append(proto)
    await asyncio.gather(*(c.done for c in clients))
    elapsed = time.perf_counter() - t0

    server.close()
    await server.wait_closed()
    return elapsed


def bench_loop_factory(name, factory, args):
    best = None
    for _ in range(args.repeat):
        loop = factory()
        gc.collect()
        try:
            elapsed = loop.run_until_complete(
                _run(loop, args.connections, args.size, args.rounds))
        finally:
            loop.close()
        best = elapsed if best is None else min(best, elapsed)
    total_msgs = args.connections * args.rounds
    total_bytes = total_msgs * args.size * 2  # payload travels both ways
    return {
        "name": name,
        "time": best,
        "rps": total_msgs / best,
        "mbps": total_bytes / best / (1024 * 1024),
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--connections", type=int, default=100)
    p.add_argument("--size", type=int, default=10240)
    p.add_argument("--rounds", type=int, default=50)
    p.add_argument("--repeat", type=int, default=3,
                   help="runs per loop; best-of is reported")
    args = p.parse_args()

    targets = []

    def asyncio_loop():
        return asyncio.new_event_loop()

    targets.append(("asyncio", asyncio_loop))

    import hvloop
    targets.append(("hvloop", hvloop.new_event_loop))

    try:
        import uvloop
        targets.append(("uvloop", uvloop.new_event_loop))
    except ImportError:
        print("uvloop not installed; skipping", file=sys.stderr)

    print(f"TCP echo: {args.connections} conns x {args.rounds} rounds x "
          f"{args.size}B (best of {args.repeat})")
    print(f"python {sys.version.split()[0]} on {platform.platform()}\n")

    results = [bench_loop_factory(name, factory, args)
               for name, factory in targets]
    base = next(r for r in results if r["name"] == "asyncio")

    hdr = f"{'loop':<10}{'time (s)':>10}{'roundtrips/s':>14}{'MiB/s':>10}{'vs asyncio':>12}"
    print(hdr)
    print("-" * len(hdr))
    for r in results:
        rel = base["time"] / r["time"]
        print(f"{r['name']:<10}{r['time']:>10.3f}{r['rps']:>14,.0f}"
              f"{r['mbps']:>10.1f}{rel:>11.2f}x")


if __name__ == "__main__":
    main()
