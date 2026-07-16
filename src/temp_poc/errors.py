from dataclasses import dataclass
from typing import override


@dataclass(frozen=True, slots=True)
class DatasetError(Exception):
    reason: str

    @override
    def __str__(self) -> str:
        return f"invalid dataset: {self.reason}"


@dataclass(frozen=True, slots=True)
class ServiceCallError(Exception):
    operation: str
    detail: str

    @override
    def __str__(self) -> str:
        return f"{self.operation} failed: {self.detail}"
