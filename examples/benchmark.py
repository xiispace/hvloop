"""
Performance benchmark comparing asyncio and hvloop
"""
import time
import asyncio
import hvloop


async def benchmark_task():
    """A simple task that does nothing"""
    await asyncio.sleep(0)


async def run_benchmark(task_count=10000):
    """Run benchmark with specified number of tasks"""
    start = time.perf_counter()

    tasks = [benchmark_task() for _ in range(task_count)]
    await asyncio.gather(*tasks)

    return time.perf_counter() - start


def main():
    """Run benchmarks comparing asyncio and hvloop"""
    task_count = 10000

    print(f"Benchmarking with {task_count} tasks...")

    # Test with standard asyncio
    print("\nTesting with standard asyncio...")
    asyncio_time = asyncio.run(run_benchmark(task_count))
    print(f"asyncio time: {asyncio_time:.3f}s")

    # Test with hvloop
    print("\nTesting with hvloop...")
    hvloop.install()
    hvloop_time = asyncio.run(run_benchmark(task_count))
    print(f"hvloop time:  {hvloop_time:.3f}s")

    # Calculate speedup
    speedup = asyncio_time / hvloop_time
    print(f"\nSpeedup: {speedup:.1f}x")

    return speedup


if __name__ == "__main__":
    main()