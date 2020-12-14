import asyncio as __asyncio
from asyncio.events import BaseDefaultEventLoopPolicy as __BasePolicy

from .loop import Loop as __BaseLoop

__all__ = ('new_event_loop', 'install', 'EventLoopPolicy')


class Loop(__BaseLoop, __asyncio.AbstractEventLoop):
    pass


def new_event_loop():
    """Return a new event loop."""
    return Loop()


def install():
    __asyncio.set_event_loop_policy(EventLoopPolicy())


class EventLoopPolicy(__BasePolicy):

    def _loop_factory(self):
        return new_event_loop()
