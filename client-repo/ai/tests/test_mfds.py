from __future__ import annotations

import threading
import time
from dataclasses import FrozenInstanceError

import httpx
import pytest

from app.clients.mfds import (
    DurQuery,
    MedicationLookupStatus,
    MedicationQuery,
    MfdsClient,
)
from app.errors import UpstreamError


class FakeClock:
    def __init__(self, value: float = 100.0) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


def _client(
    handler: httpx.MockTransport,
    *,
    clock: FakeClock | None = None,
    service_key: str | None = "top-secret-key",
    base_url: str = "https://mfds.example.test/1471000",
    cache_ttl_seconds: float = 24 * 60 * 60,
) -> MfdsClient:
    return MfdsClient(
        service_key=service_key,
        base_url=base_url,
        transport=handler,
        clock=clock or time.monotonic,
        cache_ttl_seconds=cache_ttl_seconds,
    )


def _payload(
    *,
    total_count: int,
    page_number: int = 1,
    items: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    body: dict[str, object] = {
        "pageNo": page_number,
        "totalCount": total_count,
        "numOfRows": 500,
    }
    if items is not None:
        body["items"] = items
    return {
        "header": {"resultCode": "00", "resultMsg": "NORMAL SERVICE."},
        "body": body,
    }


def _row(
    *,
    ingredient: str = "D000001",
    mixture: str = "D000002",
    dur_seq: str = "19",
    content: str | None = "함께 복용하면 안 됩니다",
) -> dict[str, object]:
    return {
        "INGR_CODE": ingredient,
        "MIXTURE_INGR_CODE": mixture,
        "DUR_SEQ": dur_seq,
        "PROHBT_CONTENT": content,
    }


def _assert_public_error(error: UpstreamError) -> None:
    assert error.status_code == 502
    assert error.code == "DUR_UPSTREAM_ERROR"
    assert error.message
    assert "top-secret-key" not in error.message
    assert "mfds.example.test" not in error.message
    assert error.__cause__ is None


def test_product_lookup_uses_expected_operation_params_and_item_sequences() -> None:
    calls: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return httpx.Response(
            200,
            json=_payload(
                total_count=2,
                items=[{"ITEM_SEQ": "100"}, {"ITEM_SEQ": "200"}],
            ),
        )

    with _client(httpx.MockTransport(handler)) as client:
        result = client.lookup_product("  바이테롤정   ")

    assert result.exists is True
    assert result.item_name == "바이테롤정"
    assert result.item_sequences == ("100", "200")
    assert len(calls) == 1
    request = calls[0]
    assert request.method == "GET"
    assert request.url.path.endswith("/getDurPrdlstInfoList03")
    assert request.url.params["serviceKey"] == "top-secret-key"
    assert request.url.params["itemName"] == "바이테롤정"
    assert request.url.params["type"] == "json"
    assert request.url.params["numOfRows"] == "500"
    assert request.url.params["pageNo"] == "1"
    assert request.extensions["timeout"]["connect"] == 5.0
    assert request.extensions["timeout"]["read"] == 10.0


def test_raw_name_spacing_is_preserved_and_both_successes_are_cached() -> None:
    calls: list[tuple[str, str | None]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        operation = request.url.path.rsplit("/", 1)[-1]
        item_name = request.url.params.get("itemName")
        calls.append((operation, item_name))
        assert item_name == "원문   이름"
        if operation == "getDurPrdlstInfoList03":
            return httpx.Response(
                200,
                json=_payload(total_count=1, items=[{"ITEM_SEQ": "raw-seq"}]),
            )
        return httpx.Response(200, json=_payload(total_count=1, items=[_row()]))

    query = MedicationQuery.by_name_candidates("  원문   이름  ", "원문 이름")
    with _client(httpx.MockTransport(handler)) as client:
        first = client.lookup_many((query,))[0]
        second = client.lookup_many((query,))[0]

    assert first == second
    assert first.status is MedicationLookupStatus.VERIFIED
    assert first.matched_item_name == "원문   이름"
    assert calls == [
        ("getDurPrdlstInfoList03", "원문   이름"),
        ("getUsjntTabooInfoList03", "원문   이름"),
    ]


def test_normal_zero_result_without_items_is_success_and_is_cached() -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(httpx.MockTransport(handler)) as client:
        first = client.lookup_product("없는   약")
        second = client.lookup_product(" 없는   약 ")

    assert first == second
    assert first.exists is False
    assert first.item_sequences == ()
    assert calls == 1


@pytest.mark.parametrize(
    "response_factory",
    [
        lambda: httpx.Response(
            200,
            json={
                "header": {"resultCode": "11", "resultMsg": "parameter error"},
                "body": {},
            },
        ),
        lambda: httpx.Response(
            403,
            json={
                "OpenAPI_ServiceResponse": {
                    "cmmMsgHeader": {"errMsg": "SERVICE_KEY_IS_NOT_REGISTERED_ERROR"}
                }
            },
        ),
        lambda: httpx.Response(200, text="temporarily unavailable"),
        lambda: httpx.Response(200, json={"body": {"totalCount": 0}}),
        lambda: httpx.Response(200, json=_payload(total_count=1)),
    ],
    ids=[
        "result-code-error",
        "http-403-shape",
        "non-json-200",
        "missing-header",
        "positive-count-without-items",
    ],
)
def test_invalid_response_shapes_are_retried_then_wrapped(
    response_factory: object,
) -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        assert callable(response_factory)
        return response_factory()

    with _client(httpx.MockTransport(handler)) as client:
        with pytest.raises(UpstreamError) as caught:
            client.lookup_product("바이테롤정")

    assert calls == 2
    _assert_public_error(caught.value)


def test_contraindication_lookup_reads_every_page_and_condenses_rows() -> None:
    requested_pages: list[int] = []
    repeated = _row(content="  횡문근융해증\n")

    def handler(request: httpx.Request) -> httpx.Response:
        page = int(request.url.params["pageNo"])
        requested_pages.append(page)
        if page == 1:
            items = [dict(repeated) for _ in range(500)]
        else:
            items = [
                _row(
                    ingredient="D000350",
                    mixture="D000762",
                    dur_seq="1041",
                    content=None,
                )
            ]
        return httpx.Response(
            200,
            json=_payload(total_count=501, page_number=page, items=items),
        )

    with _client(httpx.MockTransport(handler)) as client:
        profile = client.lookup_contraindications(DurQuery.by_name("바이테롤정"))

    assert sorted(requested_pages) == [1, 2]
    assert profile.too_broad is False
    assert profile.total_count == 501
    assert profile.ingredient_codes == frozenset({"D000001", "D000350"})
    assert profile.evidence_for("D000002")[0].prohibition_content == "횡문근융해증"
    assert profile.evidence_for("D000762")[0].dur_seq == "1041"
    assert profile.evidence_for("D000762")[0].prohibition_content is None
    assert isinstance(profile.contraindications, tuple)
    with pytest.raises(FrozenInstanceError):
        profile.total_count = 1  # type: ignore[misc]


def test_row_count_mismatch_fails_and_partial_result_is_not_cached() -> None:
    calls = 0
    mismatch = True

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        page = int(request.url.params["pageNo"])
        first_page_size = 499 if mismatch else 500
        items = [_row()] * (first_page_size if page == 1 else 1)
        return httpx.Response(
            200,
            json=_payload(total_count=501, page_number=page, items=items),
        )

    with _client(httpx.MockTransport(handler)) as client:
        with pytest.raises(UpstreamError):
            client.lookup_contraindications(DurQuery.by_name("바이테롤정"))

        mismatch = False
        result = client.lookup_contraindications(DurQuery.by_name("바이테롤정"))
        cached = client.lookup_contraindications(DurQuery.by_name("바이테롤정"))

    assert result == cached
    assert calls == 4


def test_more_than_five_thousand_rows_is_marked_broad_stops_and_is_not_cached() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        assert request.url.params["pageNo"] == "1"
        return httpx.Response(
            200,
            json=_payload(total_count=5_001, items=[_row()]),
        )

    with _client(httpx.MockTransport(handler)) as client:
        first = client.lookup_contraindications(DurQuery.by_name("너무 넓은 이름"))
        second = client.lookup_contraindications(DurQuery.by_name("너무 넓은 이름"))

    assert first.too_broad is True
    assert first.total_count == 5_001
    assert first.ingredient_codes == frozenset()
    assert first.contraindications == ()
    assert second == first
    assert calls == 2


def test_transport_timeout_is_retried_once_and_only_success_is_cached() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls <= 2:
            raise httpx.ReadTimeout("request URL must not escape", request=request)
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(httpx.MockTransport(handler)) as client:
        with pytest.raises(UpstreamError) as caught:
            client.lookup_contraindications(DurQuery.by_name("약 이름"))
        result = client.lookup_contraindications(DurQuery.by_name("약 이름"))
        cached = client.lookup_contraindications(DurQuery.by_name("약 이름"))

    _assert_public_error(caught.value)
    assert result == cached
    assert calls == 3


def test_total_deadline_is_enforced_without_a_retry_after_budget_expires() -> None:
    clock = FakeClock()
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        clock.advance(21)
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(httpx.MockTransport(handler), clock=clock) as client:
        with pytest.raises(UpstreamError) as caught:
            client.lookup_contraindications(DurQuery.by_name("약 이름"))

    assert calls == 1
    _assert_public_error(caught.value)


def test_success_cache_expires_after_twenty_four_hours() -> None:
    clock = FakeClock()
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(httpx.MockTransport(handler), clock=clock) as client:
        first = client.lookup_contraindications(DurQuery.by_name("약 이름"))
        clock.advance((24 * 60 * 60) - 1)
        second = client.lookup_contraindications(DurQuery.by_name("약 이름"))
        clock.advance(2)
        third = client.lookup_contraindications(DurQuery.by_name("약 이름"))

    assert first == second == third
    assert calls == 2


def test_lookup_many_resolves_name_fallbacks_and_skips_product_for_item_seq() -> None:
    calls: list[tuple[str, str | None, str | None]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        operation = request.url.path.rsplit("/", 1)[-1]
        item_name = request.url.params.get("itemName")
        item_seq = request.url.params.get("itemSeq")
        calls.append((operation, item_name, item_seq))
        if operation == "getDurPrdlstInfoList03":
            if item_name == "원문 이름":
                return httpx.Response(200, json=_payload(total_count=0))
            return httpx.Response(
                200,
                json=_payload(
                    total_count=1,
                    items=[
                        {
                            "ITEM_SEQ": "matched-seq",
                            # This field cannot be used to skip the DUR query.
                            "TYPE_NAME  ": "임부금기, 첨가제주의",
                        }
                    ],
                ),
            )
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(httpx.MockTransport(handler)) as client:
        results = client.lookup_many(
            (
                MedicationQuery.by_name_candidates("원문 이름", "정리 이름", "사용 안 함"),
                MedicationQuery.by_item_seq("exact-seq"),
            )
        )

    name_result, exact_result = results
    assert name_result.status is MedicationLookupStatus.VERIFIED
    assert name_result.matched_item_name == "정리 이름"
    assert name_result.item_sequences == ("matched-seq",)
    assert name_result.profile is not None
    assert exact_result.status is MedicationLookupStatus.VERIFIED
    assert exact_result.matched_item_name is None
    assert exact_result.profile is not None
    assert all(call[1] != "사용 안 함" for call in calls)
    assert not any(
        operation == "getDurPrdlstInfoList03" and item_seq == "exact-seq"
        for operation, _item_name, item_seq in calls
    )
    assert any(
        operation == "getUsjntTabooInfoList03" and item_seq == "exact-seq"
        for operation, _item_name, item_seq in calls
    )


def test_lookup_many_distinguishes_not_found_and_too_broad() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        operation = request.url.path.rsplit("/", 1)[-1]
        item_name = request.url.params.get("itemName")
        if operation == "getDurPrdlstInfoList03":
            if item_name == "없는 약":
                return httpx.Response(200, json=_payload(total_count=0))
            return httpx.Response(
                200,
                json=_payload(total_count=1, items=[{"ITEM_SEQ": "one"}]),
            )
        return httpx.Response(200, json=_payload(total_count=5_001, items=[_row()]))

    with _client(httpx.MockTransport(handler)) as client:
        missing, broad = client.lookup_many(
            (
                MedicationQuery.by_name_candidates("없는 약"),
                MedicationQuery.by_name_candidates("너무 넓은 약"),
            )
        )

    assert missing.status is MedicationLookupStatus.NOT_FOUND
    assert missing.profile is None
    assert broad.status is MedicationLookupStatus.TOO_BROAD
    assert broad.profile is not None
    assert broad.profile.too_broad is True


def test_http_concurrency_never_exceeds_three() -> None:
    active = 0
    maximum_active = 0
    lock = threading.Lock()

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal active, maximum_active
        with lock:
            active += 1
            maximum_active = max(maximum_active, active)
        time.sleep(0.03)
        with lock:
            active -= 1
        return httpx.Response(200, json=_payload(total_count=0))

    queries = tuple(DurQuery.by_name(f"약 {index}") for index in range(8))
    with _client(httpx.MockTransport(handler)) as client:
        results = client.lookup_contraindications_many(queries)

    assert len(results) == len(queries)
    assert maximum_active == 3


def test_remaining_contraindication_pages_are_downloaded_in_parallel() -> None:
    active_pages = 0
    maximum_active_pages = 0
    lock = threading.Lock()

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal active_pages, maximum_active_pages
        page = int(request.url.params["pageNo"])
        if page == 1:
            items = [_row()] * 500
        else:
            with lock:
                active_pages += 1
                maximum_active_pages = max(maximum_active_pages, active_pages)
            time.sleep(0.03)
            with lock:
                active_pages -= 1
            items = [_row()] * (500 if page == 2 else 1)
        return httpx.Response(
            200,
            json=_payload(total_count=1_001, page_number=page, items=items),
        )

    with _client(httpx.MockTransport(handler)) as client:
        profile = client.lookup_contraindications(DurQuery.by_name("세 페이지 약"))

    assert profile.total_count == 1_001
    assert maximum_active_pages == 2


@pytest.mark.parametrize(
    ("service_key", "base_url"),
    [
        (None, "https://mfds.example.test/1471000"),
        ("top-secret-key", "http://mfds.example.test/1471000"),
    ],
)
def test_missing_key_or_insecure_url_fails_without_an_http_call(
    service_key: str | None,
    base_url: str,
) -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(200, json=_payload(total_count=0))

    with _client(
        httpx.MockTransport(handler),
        service_key=service_key,
        base_url=base_url,
    ) as client:
        with pytest.raises(UpstreamError) as caught:
            client.lookup_product("약 이름")

    assert calls == 0
    _assert_public_error(caught.value)
