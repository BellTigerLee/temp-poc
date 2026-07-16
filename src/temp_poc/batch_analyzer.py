from __future__ import annotations

import logging
import os
from typing import TYPE_CHECKING, ClassVar, Final

import httpx2
from pydantic import AnyHttpUrl, BaseModel, ConfigDict, ValidationError

from temp_poc.dataset import analyze_dataset
from temp_poc.errors import DatasetError, ServiceCallError
from temp_poc.http_client import create_client

if TYPE_CHECKING:
    from temp_poc.models import AnalysisResult

LOGGER: Final = logging.getLogger(__name__)


class AnalyzerSettings(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True)

    dataset_url: AnyHttpUrl
    report_url: AnyHttpUrl

    @classmethod
    def from_environment(cls) -> AnalyzerSettings:
        return cls.model_validate(
            {
                "dataset_url": os.environ.get("DATASET_URL"),
                "report_url": os.environ.get("REPORT_URL"),
            }
        )


def execute(settings: AnalyzerSettings) -> AnalysisResult:
    with create_client() as client:
        dataset_response = client.get(str(settings.dataset_url))
        _ = dataset_response.raise_for_status()
        result = analyze_dataset(dataset_response.content)
        report_response = client.post(
            str(settings.report_url),
            content=result.model_dump_json(by_alias=True),
            headers={"content-type": "application/json"},
        )
        _ = report_response.raise_for_status()
    return result


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        result = execute(AnalyzerSettings.from_environment())
    except ValidationError as error:
        LOGGER.warning("invalid analyzer configuration: %s", error)
        return 2
    except DatasetError as error:
        LOGGER.warning("%s", error)
        return 1
    except httpx2.HTTPError as error:
        failure = ServiceCallError(operation="cross-cluster HTTP request", detail=str(error))
        LOGGER.warning("%s", failure)
        return 1
    LOGGER.info("published analysis for %d records", result.record_count)
    return 0
