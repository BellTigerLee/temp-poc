from __future__ import annotations

import logging
import socket
from typing import Final

import httpx2

LOGGER: Final = logging.getLogger(__name__)
LIMITS: Final = httpx2.Limits(
    max_connections=200,
    max_keepalive_connections=40,
    keepalive_expiry=30.0,
)
TIMEOUT: Final = httpx2.Timeout(connect=5.0, read=30.0, write=10.0, pool=10.0)
SOCKET_OPTIONS: Final = [(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)]


def _log_request(request: httpx2.Request) -> None:
    LOGGER.info("HTTP %s %s", request.method, request.url)


def _log_response(response: httpx2.Response) -> None:
    LOGGER.info(
        "HTTP %s %s -> %d (%s)",
        response.request.method,
        response.request.url,
        response.status_code,
        response.http_version,
    )


def create_client() -> httpx2.Client:
    transport = httpx2.HTTPTransport(
        http2=True,
        retries=3,
        limits=LIMITS,
        socket_options=SOCKET_OPTIONS,
    )
    return httpx2.Client(
        transport=transport,
        timeout=TIMEOUT,
        follow_redirects=True,
        event_hooks={"request": [_log_request], "response": [_log_response]},
    )
