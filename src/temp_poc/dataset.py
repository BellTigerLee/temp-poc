from __future__ import annotations

import csv
import io
from decimal import Decimal, InvalidOperation, localcontext
from typing import ClassVar, Final

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from temp_poc.errors import DatasetError
from temp_poc.models import AnalysisResult

DATASET_BYTES: Final = (
    b"record_id,label,amount\n"
    b"1,alpha,10.00\n"
    b"2,beta,20.00\n"
    b"3,gamma,30.00\n"
    b"4,delta,40.00\n"
    b"5,epsilon,50.00\n"
)
EXPECTED_COLUMNS: Final = ("record_id", "label", "amount")
CENT: Final = Decimal("0.01")


class CsvRow(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    record_id: int = Field(ge=1)
    label: str = Field(min_length=1)
    amount: Decimal = Field(ge=0, decimal_places=2, allow_inf_nan=False)


def parse_dataset(payload: bytes) -> tuple[CsvRow, ...]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise DatasetError(reason="input is not UTF-8") from error

    reader = csv.DictReader(io.StringIO(text, newline=""))
    if tuple(reader.fieldnames or ()) != EXPECTED_COLUMNS:
        raise DatasetError(reason="unexpected CSV header")

    try:
        rows = tuple(CsvRow.model_validate(raw) for raw in reader)
    except (ValidationError, InvalidOperation) as error:
        raise DatasetError(reason="malformed CSV row") from error
    if not rows:
        raise DatasetError(reason="CSV contains no rows")
    identifiers = tuple(row.record_id for row in rows)
    if len(identifiers) != len(set(identifiers)):
        raise DatasetError(reason="duplicate record_id")
    return rows


def analyze_dataset(payload: bytes) -> AnalysisResult:
    rows = parse_dataset(payload)
    with localcontext() as context:
        context.prec = 28
        total = sum((row.amount for row in rows), start=Decimal()).quantize(CENT)
        average = (total / Decimal(len(rows))).quantize(CENT)
    return AnalysisResult(
        recordCount=len(rows),
        amountSum=total,
        amountAverage=average,
    )
