from typing import Final

import uvicorn
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, Response

from temp_poc.dataset import DATASET_BYTES

APP_TITLE: Final = "temp-poc dataset-ingest"
LISTEN_HOST: Final = "0.0.0.0"
app = FastAPI(title=APP_TITLE)


@app.get("/healthz", response_class=PlainTextResponse)
async def healthz() -> str:
    return "ok\n"


@app.get("/dataset.csv", response_class=Response)
async def dataset() -> Response:
    return Response(content=DATASET_BYTES, media_type="text/csv")


def main() -> None:
    uvicorn.run(app, host=LISTEN_HOST, port=8080)
