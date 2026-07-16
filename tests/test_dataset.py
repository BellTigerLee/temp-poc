from decimal import Decimal

import pytest

from temp_poc.dataset import DATASET_BYTES, analyze_dataset, parse_dataset
from temp_poc.errors import DatasetError


def test_dataset_has_exact_aggregate() -> None:
    result = analyze_dataset(DATASET_BYTES)

    assert result.record_count == 5
    assert result.amount_sum == Decimal("150.00")
    assert result.amount_average == Decimal("30.00")


def test_dataset_rejects_duplicate_identifiers() -> None:
    payload = b"record_id,label,amount\n1,a,1.00\n1,b,2.00\n"

    with pytest.raises(DatasetError, match="duplicate record_id"):
        _ = parse_dataset(payload)
