"""Shared pytest configuration for the hvloop test suite.

Most hvloop tests are *synchronous* functions that construct their own Loop and
drive it explicitly (run_forever / run_until_complete). The project-level
pytest config sets ``asyncio_mode = "auto"``, which would otherwise try to run
every ``async def`` test on the stdlib loop. We don't want that to interfere,
so async coroutine-style assertions in this suite are driven manually via
``hvloop.run(...)`` inside synchronous tests rather than relying on
pytest-asyncio's auto mode.
"""

import pytest

import hvloop


@pytest.fixture
def loop():
    """Provide a fresh hvloop event loop, closed on teardown."""
    lp = hvloop.new_event_loop()
    try:
        yield lp
    finally:
        if not lp.is_closed():
            lp.close()
