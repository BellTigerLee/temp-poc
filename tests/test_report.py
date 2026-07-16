from decimal import Decimal

import anyio

from temp_poc.models import AnalysisResult
from temp_poc.report_generator import ReportStore, render_report


def test_report_store_round_trip() -> None:
    result = AnalysisResult(
        recordCount=5, amountSum=Decimal("150.00"), amountAverage=Decimal("30.00")
    )

    async def scenario() -> None:
        store = ReportStore()
        assert await store.snapshot() is None
        await store.publish(result)
        assert await store.snapshot() == result

    anyio.run(scenario)


def test_report_html_contains_result() -> None:
    result = AnalysisResult(
        recordCount=5, amountSum=Decimal("150.00"), amountAverage=Decimal("30.00")
    )

    rendered = render_report(result)

    assert "temp-poc analysis" in rendered
    assert "150.00" in rendered
    assert "30.00" in rendered
