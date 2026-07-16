from __future__ import annotations

from html import escape
from typing import TYPE_CHECKING, Final, final

import anyio
import uvicorn
from fastapi import FastAPI, HTTPException, Response, status
from fastapi.responses import HTMLResponse, PlainTextResponse

from temp_poc.models import AnalysisResult

if TYPE_CHECKING:
    from decimal import Decimal


@final
class ReportStore:
    def __init__(self) -> None:
        self._lock: anyio.Lock = anyio.Lock()
        self._result: AnalysisResult | None = None

    async def publish(self, result: AnalysisResult) -> None:
        async with self._lock:
            self._result = result

    async def snapshot(self) -> AnalysisResult | None:
        async with self._lock:
            return self._result


STORE: Final = ReportStore()
LISTEN_HOST: Final = "0.0.0.0"
app = FastAPI(title="temp-poc report-generator")


def _format_decimal(value: Decimal) -> str:
    return escape(format(value, ".2f"))


def render_report(result: AnalysisResult | None) -> str:
    if result is None:
        body = "<h1>temp-poc</h1><p>Waiting for the c-cluster analyzer.</p>"
    else:
        body = (
            "<h1>temp-poc analysis</h1>"
            f"<dl><dt>Records</dt><dd>{result.record_count}</dd>"
            f"<dt>Amount sum</dt><dd>{_format_decimal(result.amount_sum)}</dd>"
            f"<dt>Amount average</dt><dd>{_format_decimal(result.amount_average)}</dd></dl>"
        )
    return f"<!doctype html><html><head><title>temp-poc</title></head><body>{body}</body></html>"


@app.get("/healthz", response_class=PlainTextResponse)
async def healthz() -> str:
    return "ok\n"


@app.post("/result", status_code=status.HTTP_204_NO_CONTENT)
async def publish_result(result: AnalysisResult) -> Response:
    await STORE.publish(result)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.get("/result.json", response_model=AnalysisResult)
async def result_json() -> AnalysisResult:
    result = await STORE.snapshot()
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="analysis not available")
    return result


@app.get("/", response_class=HTMLResponse)
async def index() -> str:
    return render_report(await STORE.snapshot())


def main() -> None:
    uvicorn.run(app, host=LISTEN_HOST, port=8080)
