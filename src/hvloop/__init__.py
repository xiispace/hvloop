"""hvloop: an asyncio-compatible event loop backed by libhv.

Public API (M1):

    import hvloop

    hvloop.install()                 # set hvloop as the default policy
    loop = hvloop.new_event_loop()   # construct a Loop directly
    hvloop.run(main())               # run a coroutine to completion
"""

from __future__ import annotations

import asyncio as _asyncio
import sys as _sys
import typing as _typing

from ._core import Loop as _CoreLoop

__all__ = (
    "Loop",
    "EventLoopPolicy",
    "new_event_loop",
    "install",
    "uninstall",
    "run",
)

__version__ = "0.2.0"


class Loop(_CoreLoop, _asyncio.AbstractEventLoop):
    """The hvloop event loop.

    ``_core.Loop`` is a Cython ``cdef class`` and cannot directly inherit from
    the pure-Python ``AbstractEventLoop`` ABC, so we compose them here (the
    same pattern uvloop uses). The concrete C methods satisfy the abstract
    interface; ABCMeta's ``__subclasshook__`` accepts the subclass because all
    abstract methods are provided.
    """


def new_event_loop() -> Loop:
    """Create and return a new hvloop event loop."""
    return Loop()


class EventLoopPolicy(_asyncio.DefaultEventLoopPolicy):
    """An event loop policy whose ``new_event_loop`` returns an hvloop Loop.

    Mirrors uvloop.EventLoopPolicy: only the loop factory changes; child
    watcher / loop bookkeeping is inherited from the default policy.
    """

    def _loop_factory(self) -> Loop:  # type: ignore[override]
        return new_event_loop()

    if _typing.TYPE_CHECKING:
        # The base class declares these; keep type checkers happy without
        # changing runtime behavior.
        def get_event_loop(self) -> Loop: ...

        def new_event_loop(self) -> Loop: ...


def install() -> None:
    """Set hvloop as the global asyncio event loop policy.

    Equivalent to ``asyncio.set_event_loop_policy(hvloop.EventLoopPolicy())``.
    """
    _asyncio.set_event_loop_policy(EventLoopPolicy())


def uninstall() -> None:
    """Restore the default asyncio event loop policy."""
    _asyncio.set_event_loop_policy(None)


def run(main, *, debug: bool | None = None, loop_factory=None):
    """Run a coroutine on a fresh hvloop event loop, then clean up.

    On Python 3.11+ this delegates to ``asyncio.Runner(loop_factory=...)`` so
    that ``run_until_complete``, ``shutdown_asyncgens`` and
    ``shutdown_default_executor`` semantics match the stdlib exactly. On 3.10
    a hand-rolled equivalent is used.
    """
    if not _asyncio.iscoroutine(main):
        raise ValueError(f"a coroutine was expected, got {main!r}")

    if loop_factory is None:
        loop_factory = new_event_loop

    if _sys.version_info >= (3, 11):
        with _asyncio.Runner(debug=debug, loop_factory=loop_factory) as runner:
            return runner.run(main)

    # Python 3.10 fallback: replicate asyncio.run() against our loop factory.
    if _asyncio.events._get_running_loop() is not None:
        raise RuntimeError(
            "hvloop.run() cannot be called from a running event loop"
        )
    loop = loop_factory()
    try:
        _asyncio.set_event_loop(loop)
        if debug is not None:
            loop.set_debug(debug)
        return loop.run_until_complete(main)
    finally:
        try:
            _cancel_all_tasks(loop)
            loop.run_until_complete(loop.shutdown_asyncgens())
            loop.run_until_complete(loop.shutdown_default_executor())
        finally:
            _asyncio.set_event_loop(None)
            loop.close()


def _cancel_all_tasks(loop) -> None:
    to_cancel = _asyncio.all_tasks(loop)
    if not to_cancel:
        return
    for task in to_cancel:
        task.cancel()
    loop.run_until_complete(
        _asyncio.gather(*to_cancel, return_exceptions=True)
    )
    for task in to_cancel:
        if task.cancelled():
            continue
        if task.exception() is not None:
            loop.call_exception_handler(
                {
                    "message": "unhandled exception during hvloop.run() shutdown",
                    "exception": task.exception(),
                    "task": task,
                }
            )
