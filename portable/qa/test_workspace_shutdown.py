"""A disconnected client cannot leave the threaded browser-test server running."""
import asyncio
from contextlib import asynccontextmanager
import socket
import threading

from fastapi import FastAPI, Response

from e2e_suite.harness import qa_server


def test_threaded_server_drains_held_request_and_releases_listener():
    entered = threading.Event()
    cancelled = threading.Event()
    lifespan_ended = threading.Event()
    release = threading.Event()

    @asynccontextmanager
    async def lifespan(_):
        yield
        lifespan_ended.set()

    app = FastAPI(lifespan=lifespan)

    @app.get("/held")
    async def held():
        entered.set()
        try:
            while not release.is_set():
                await asyncio.sleep(0.05)
        except asyncio.CancelledError:
            cancelled.set()
        return Response(status_code=204)

    server = qa_server(app)
    with socket.create_server(("127.0.0.1", 0)) as listener:
        address = listener.getsockname()
        thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
        thread.start()
        try:
            with socket.create_connection(address, timeout=5) as peer:
                peer.sendall(b"GET /held HTTP/1.1\r\nHost: localhost\r\n\r\n")
                assert entered.wait(5), "The held request did not reach the app"
            server.should_exit = True
            thread.join(timeout=10)
            assert not thread.is_alive(), "The request outlived the fixture's shutdown budget"
            assert cancelled.is_set() and lifespan_ended.is_set()
        finally:
            release.set()  # Also unblock the handler if the shutdown regression returns.
            server.should_exit = True
            if thread.is_alive():
                thread.join(timeout=10)
    with socket.create_server(address) as rebound:
        assert rebound.getsockname() == address
