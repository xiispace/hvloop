"""Minimal smoke tests: stdlib asyncio primitives on top of hvloop.

asyncio.sleep / gather / wait_for rely only on call_soon / call_at / Future,
which M1 provides, so they must work end-to-end on an hvloop loop.
"""

import asyncio

import pytest

import hvloop


def test_asyncio_sleep(loop):
    async def main():
        t0 = loop.time()
        await asyncio.sleep(0.05)
        return loop.time() - t0

    elapsed = loop.run_until_complete(main())
    assert elapsed >= 0.04


def test_asyncio_gather(loop):
    async def work(n):
        await asyncio.sleep(0.01 * n)
        return n * n

    async def main():
        return await asyncio.gather(work(1), work(2), work(3))

    assert loop.run_until_complete(main()) == [1, 4, 9]


def test_asyncio_gather_with_exception(loop):
    async def good():
        await asyncio.sleep(0.01)
        return "ok"

    async def bad():
        await asyncio.sleep(0.01)
        raise ValueError("nope")

    async def main():
        return await asyncio.gather(good(), bad(), return_exceptions=True)

    results = loop.run_until_complete(main())
    assert results[0] == "ok"
    assert isinstance(results[1], ValueError)


def test_asyncio_wait_for_timeout(loop):
    async def main():
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(asyncio.sleep(10), timeout=0.05)
        return "timed-out"

    assert loop.run_until_complete(main()) == "timed-out"


def test_asyncio_wait_for_completes(loop):
    async def quick():
        await asyncio.sleep(0.01)
        return "value"

    async def main():
        return await asyncio.wait_for(quick(), timeout=1.0)

    assert loop.run_until_complete(main()) == "value"


def test_nested_tasks(loop):
    async def child(n):
        await asyncio.sleep(0.005)
        return n

    async def parent():
        tasks = [asyncio.ensure_future(child(i)) for i in range(5)]
        results = await asyncio.gather(*tasks)
        return sum(results)

    assert loop.run_until_complete(parent()) == 10


def test_event_synchronization(loop):
    async def main():
        ev = asyncio.Event()

        async def setter():
            await asyncio.sleep(0.02)
            ev.set()

        asyncio.ensure_future(setter())
        await ev.wait()
        return "set"

    assert loop.run_until_complete(main()) == "set"


def test_hvloop_run_helper():
    async def main():
        await asyncio.sleep(0.01)
        return "hvloop.run works"

    assert hvloop.run(main()) == "hvloop.run works"


def test_hvloop_run_rejects_non_coroutine():
    with pytest.raises(ValueError):
        hvloop.run(123)


def test_install_uninstall():
    hvloop.install()
    try:
        policy = asyncio.get_event_loop_policy()
        assert isinstance(policy, hvloop.EventLoopPolicy)
        new_loop = policy.new_event_loop()
        try:
            assert isinstance(new_loop, hvloop.Loop)
        finally:
            new_loop.close()
    finally:
        hvloop.uninstall()
