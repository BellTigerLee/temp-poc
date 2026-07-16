from decimal import Decimal
from typing import ClassVar

from pydantic import BaseModel, ConfigDict, Field


class AnalysisResult(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(
        frozen=True,
        populate_by_name=True,
        serialize_by_alias=True,
    )

    record_count: int = Field(alias="recordCount", ge=1)
    amount_sum: Decimal = Field(alias="amountSum", ge=0, decimal_places=2)
    amount_average: Decimal = Field(alias="amountAverage", ge=0, decimal_places=2)
