#!/usr/bin/env python3
"""uvicorn hello-world RPS: hvloop vs asyncio (vs uvloop when installed).

Methodology (tech design section 12.4)
--------------------------------------
For each loop implementation, a *subprocess* runs
``uvicorn.run(app, loop=<spec>)`` with a minimal raw-ASGI hello-world app
(no framework overhead), so each server owns a clean process and its own
loop built through uvicorn's real loop-factory path. The load generator is
self-contained (no wrk/oha dependency): it runs in the parent process on a
plain asyncio loop, opening N keep-alive connections that issue
pipelined-sequential ``GET /`` requests for D seconds; completed responses
are parsed (status line + content-length body) and counted.

Client and server share the machine, so treat the numbers as *relative*
loop-vs-loop comparisons, not absolute capacity.

Usage:
    python benchmarks/bench_http.py [--concurrency 50] [--duration 5]
"""

from __future__ import annotations

import argparse
import asyncio
import platform
import socket
import subprocess
import sys
import time

REQUEST = (b"GET / HTTP/1.1\r\n"
           b"Host: 127.0.0.1\r\n"
           b"Connection: keep-alive\r\n\r\n")


# ---------------------------------------------------------------------------
# server subprocess: `python bench_http.py --serve --loop <spec> --port <p>`
# ---------------------------------------------------------------------------
async def app(scope, receive, send):
    if scope["type"] != "http":
        return
    await send({
        "type": "http.response.start",
        "status": 200,
        "headers": [(b"content-type", b"text/plain"),
                    (b"content-length", b"13")],
    })
    await send({"type": "http.response.body", "body": b"Hello, world!"})


def serve(loop_spec: str, port: int):
    import uvicorn
    uvicorn.run(
        "bench_http:app",
        host="127.0.0.1",
        port=port,
        loop=loop_spec,          # "asyncio" | "uvloop" | "hvloop:new_event_loop"
        http="h11",              # same HTTP impl for every loop under test
        lifespan="off",
        log_level="error",
        access_log=False,
    )


# ---------------------------------------------------------------------------
# load generator (parent process, stock asyncio loop)
# ---------------------------------------------------------------------------
async def _worker(port: int, stop_at: float, counter: list):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    try:
        while time.perf_counter() < stop_at:
            writer.write(REQUEST)
            await writer.drain()
            # status + headers
            headers = await reader.readuntil(b"\r\n\r\n")
            if not headers.startswith(b"HTTP/1.1 200"):
                raise RuntimeError(f"bad response: {headers[:40]!r}")
            # fixed 13-byte hello-world body
            await reader.readexactly(13)
            counter[0] += 1
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, OSError):
            pass


async def _load(port: int, concurrency: int, duration: float) -> int:
    counter = [0]
    stop_at = time.perf_counter() + duration
    await asyncio.gather(
        *(_worker(port, stop_at, counter) for _ in range(concurrency)))
    return counter[0]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_listening(port: int, proc, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited early (rc={proc.returncode})")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("server did not start listening")


def bench_target(name: str, loop_spec: str, args) -> dict:
    port = _free_port()
    proc = subprocess.Popen(
        [sys.executable, __file__, "--serve", "--loop", loop_spec,
         "--port", str(port)],
        cwd=str(__import__("pathlib").Path(__file__).parent),
    )
    try:
        _wait_listening(port, proc)
        # short warmup, then the measured window
        asyncio.run(_load(port, args.concurrency, 0.5))
        n = asyncio.run(_load(port, args.concurrency, args.duration))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    return {"name": name, "rps": n / args.duration}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--serve", action="store_true")
    p.add_argument("--loop", default="asyncio")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--concurrency", type=int, default=50)
    p.add_argument("--duration", type=float, default=5.0)
    args = p.parse_args()

    if args.serve:
        serve(args.loop, args.port)
        return

    targets = [("asyncio", "asyncio"), ("hvloop", "hvloop:new_event_loop")]
    try:
        import uvloop  # noqa: F401
        targets.append(("uvloop", "uvloop"))
    except ImportError:
        print("uvloop not installed; skipping", file=sys.stderr)

    print(f"uvicorn hello-world (h11): {args.concurrency} keep-alive conns, "
          f"{args.duration:.0f}s measured window")
    print(f"python {sys.version.split()[0]} on {platform.platform()}\n")

    results = [bench_target(name, spec, args) for name, spec in targets]
    base = next(r for r in results if r["name"] == "asyncio")

    hdr = f"{'loop':<10}{'RPS':>12}{'vs asyncio':>12}"
    print(hdr)
    print("-" * len(hdr))
    for r in results:
        print(f"{r['name']:<10}{r['rps']:>12,.0f}"
              f"{r['rps'] / base['rps']:>11.2f}x")


if __name__ == "__main__":
    main()
