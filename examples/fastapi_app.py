"""Runnable FastAPI + WebSocket example served on hvloop.

Two ways to run it (both use hvloop as the event loop):

1. Directly:

       python examples/fastapi_app.py

   ``main()`` calls ``uvicorn.run(app, loop="hvloop:new_event_loop")``.
   uvicorn (>= 0.36) treats any ``"module:callable"`` string as an event-loop
   *factory*, so it builds its loop by calling ``hvloop.new_event_loop()``.

2. Via the uvicorn CLI, passing the same loop factory:

       uvicorn examples.fastapi_app:app --loop hvloop:new_event_loop

NOTE: with uvicorn >= 0.36, ``hvloop.install()`` + ``--loop asyncio`` does NOT
work: uvicorn maps ``asyncio`` directly to ``asyncio.SelectorEventLoop`` and
never consults the (deprecated) asyncio event-loop policy, so that recipe
silently runs on stock asyncio. Use ``--loop hvloop:new_event_loop`` (or
``hvloop.install()`` + ``--loop none``). See README "Running uvicorn + FastAPI
on hvloop".

Then try it out::

    curl http://127.0.0.1:8000/
    curl http://127.0.0.1:8000/loopinfo     # proves which loop class is running
    curl http://127.0.0.1:8000/items/42?q=hi
    # WebSocket echo (needs the `websockets` package):
    python -m websockets ws://127.0.0.1:8000/ws

Requires: ``pip install hvloop fastapi uvicorn`` (plus ``websockets`` for /ws).
"""

from __future__ import annotations

import asyncio
import contextlib

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse


@contextlib.asynccontextmanager
async def lifespan(_app: FastAPI):
    print("hvloop example: startup")
    yield
    print("hvloop example: shutdown")


app = FastAPI(lifespan=lifespan)


@app.get("/")
async def root():
    return {"hello": "hvloop", "server": "uvicorn+fastapi"}


@app.get("/loopinfo")
async def loopinfo():
    # Sanity probe: shows the event-loop class actually serving this request.
    # Expect "hvloop.Loop" when wired correctly (see module docstring).
    cls = type(asyncio.get_running_loop())
    return {"loop_class": f"{cls.__module__}.{cls.__qualname__}"}


@app.get("/items/{item_id}")
async def read_item(item_id: int, q: str | None = None):
    return {"item_id": item_id, "q": q}


@app.get("/sync")
def sync_endpoint():
    # Plain ``def`` endpoints run in Starlette's thread pool.
    return {"mode": "sync"}


@app.get("/stream")
async def stream():
    async def gen():
        for i in range(5):
            yield f"chunk {i}\n".encode()

    return StreamingResponse(gen(), media_type="text/plain")


@app.websocket("/ws")
async def ws_echo(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            message = await ws.receive_text()
            await ws.send_text(f"echo: {message}")
    except WebSocketDisconnect:
        pass


def main() -> None:
    import uvicorn

    # loop="hvloop:new_event_loop" hands uvicorn the hvloop loop factory
    # directly -- the only wiring that works with uvicorn >= 0.36 without
    # touching the deprecated asyncio policy system.
    uvicorn.run(app, host="127.0.0.1", port=8000, loop="hvloop:new_event_loop")


if __name__ == "__main__":
    main()
