from collections.abc import Callable, Sequence
from types import SimpleNamespace

import httpx
import pytest

from app.clients.mfds import (
    DurEvidence,
    DurProfile,
    DurQuery,
    IngredientContraindications,
    MedicationDurLookup,
    MedicationLookupStatus,
    MedicationQuery,
    MfdsClient,
)
from app.errors import UpstreamError
from app.routers import dur
from app.schemas import DurCheckIn, MedicationForCheck


def _profile(
    name: str,
    *,
    ingredients: set[str] | None = None,
    contraindications: dict[str, list[tuple[str, str | None]]] | None = None,
) -> DurProfile:
    return DurProfile(
        query=DurQuery.by_name(name),
        total_count=sum(len(items) for items in (contraindications or {}).values()),
        too_broad=False,
        ingredient_codes=frozenset(ingredients or set()),
        contraindications=tuple(
            IngredientContraindications(
                mixture_ingredient_code=code,
                evidence=tuple(
                    DurEvidence(dur_seq=dur_seq, prohibition_content=content)
                    for dur_seq, content in items
                ),
            )
            for code, items in sorted((contraindications or {}).items())
        ),
    )


def _verified(query: MedicationQuery, profile: DurProfile) -> MedicationDurLookup:
    return MedicationDurLookup(
        query=query,
        status=MedicationLookupStatus.VERIFIED,
        matched_item_name=profile.query.item_name,
        item_sequences=(),
        profile=profile,
    )


def _not_found(query: MedicationQuery) -> MedicationDurLookup:
    return MedicationDurLookup(
        query=query,
        status=MedicationLookupStatus.NOT_FOUND,
        matched_item_name=None,
        item_sequences=(),
        profile=None,
    )


def _too_broad(query: MedicationQuery) -> MedicationDurLookup:
    item_name = query.item_name_candidates[0]
    profile = DurProfile(
        query=DurQuery.by_name(item_name),
        total_count=5_001,
        too_broad=True,
        ingredient_codes=frozenset(),
        contraindications=(),
    )
    return MedicationDurLookup(
        query=query,
        status=MedicationLookupStatus.TOO_BROAD,
        matched_item_name=item_name,
        item_sequences=(),
        profile=profile,
    )


class FakeClient:
    def __init__(
        self,
        resolver: Callable[[MedicationQuery], MedicationDurLookup],
    ) -> None:
        self.resolver = resolver
        self.queries: tuple[MedicationQuery, ...] = ()

    def lookup_many(
        self,
        queries: Sequence[MedicationQuery],
    ) -> tuple[MedicationDurLookup, ...]:
        self.queries = tuple(queries)
        return tuple(self.resolver(query) for query in queries)


def _medication(identifier: str, name: str, item_seq: str | None = None) -> MedicationForCheck:
    return MedicationForCheck(id=identifier, name=name, item_seq=item_seq)


def test_name_candidates_strip_dose_parenthetical_and_formulation_tail() -> None:
    assert dur._name_candidates("  바이테롤정   10/20mg ") == (
        "바이테롤정   10/20mg",
        "바이테롤정 10/20mg",
        "바이테롤정",
    )
    assert dur._name_candidates("이트라녹스정100mg") == (
        "이트라녹스정100mg",
        "이트라녹스정",
    )
    assert dur._name_candidates("리피토정10밀리그램 (저녁)") == (
        "리피토정10밀리그램 (저녁)",
        "리피토정10밀리그램",
        "리피토정",
    )
    assert dur._name_candidates("정 1mg") == ()


def test_remote_single_medication_skips_mfds_even_without_key(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(dur, "get_settings", lambda: SimpleNamespace(is_mock=False))

    def fail_if_called() -> None:
        pytest.fail("약이 한 건이면 MFDS client를 만들면 안 됩니다")

    monkeypatch.setattr(dur, "get_mfds_client", fail_if_called)
    result = dur.check_interactions(
        DurCheckIn(medications=[_medication("a", "타이레놀정")])
    )
    assert result.warnings == []


def test_pair_is_checked_in_both_directions_and_all_evidence_is_kept() -> None:
    profiles = {
        "바이테롤정": _profile(
            "바이테롤정",
            ingredients={"D-A"},
            contraindications={
                "D-B": [
                    ("20", " 횡문근융해증\n"),
                    ("1041", "근증/횡문근변성의 위험성이 증가"),
                ]
            },
        ),
        "이트라녹스정": _profile(
            "이트라녹스정",
            ingredients={"D-B"},
            contraindications={"D-A": [("19", "횡문근융해증")]},
        ),
    }

    def resolve(query: MedicationQuery) -> MedicationDurLookup:
        return _verified(query, profiles[query.item_name_candidates[-1]])

    medications = [
        _medication("a", "바이테롤정 10/20mg"),
        _medication("b", "이트라녹스정100mg"),
    ]
    result = dur._check_remote(medications, FakeClient(resolve))  # type: ignore[arg-type]

    assert len(result.warnings) == 1
    warning = result.warnings[0]
    assert warning.warning_type == "usjnt_taboo"
    assert warning.medication_ids == ["a", "b"]
    assert warning.source_code == "19"
    assert "횡문근융해증" in warning.message
    assert "근증/횡문근변성의 위험성이 증가" in warning.message
    assert warning.message.count("횡문근융해증") == 1

    reversed_result = dur._check_remote(  # type: ignore[arg-type]
        list(reversed(medications)), FakeClient(resolve)
    )
    reversed_warning = reversed_result.warnings[0]
    assert reversed_warning.medication_ids == ["b", "a"]
    assert reversed_warning.message == warning.message
    assert reversed_warning.source_code == warning.source_code


def test_raw_mfds_response_shape_flows_through_client_and_router() -> None:
    """Exercise the saved MFDS row shape, not only pre-condensed profiles."""

    def response(total_count: int, items: list[dict[str, object]] | None = None) -> dict:
        body: dict[str, object] = {"pageNo": 1, "totalCount": total_count, "numOfRows": 500}
        if items is not None:
            body["items"] = items
        return {
            "header": {"resultCode": "00", "resultMsg": "NORMAL SERVICE."},
            "body": body,
        }

    product_names: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        operation = request.url.path.rsplit("/", 1)[-1]
        item_name = request.url.params.get("itemName", "")
        if operation == "getDurPrdlstInfoList03":
            product_names.append(item_name)
            if item_name in {"바이테롤정", "이트라녹스정"}:
                return httpx.Response(
                    200,
                    json=response(1, [{"ITEM_SEQ": f"fixture-{item_name}"}]),
                )
            return httpx.Response(200, json=response(0))

        if item_name == "바이테롤정":
            rows = [
                {
                    "INGR_CODE": "D000350",
                    "MIXTURE_INGR_CODE": "D000762",
                    "DUR_SEQ": "20",
                    "PROHBT_CONTENT": "횡문근융해증",
                },
                {
                    "INGR_CODE": "D000027",
                    "MIXTURE_INGR_CODE": "D000762",
                    "DUR_SEQ": "1041",
                    "PROHBT_CONTENT": " 근증/횡문근변성의 위험성이 증가\n",
                },
            ]
        else:
            rows = [
                {
                    "INGR_CODE": "D000762",
                    "MIXTURE_INGR_CODE": "D000350",
                    "DUR_SEQ": "19",
                    "PROHBT_CONTENT": "횡문근융해증",
                }
            ]
        return httpx.Response(200, json=response(len(rows), rows))

    with MfdsClient(
        service_key="test-key",
        base_url="https://mfds.test/1471000",
        transport=httpx.MockTransport(handler),
    ) as client:
        result = dur._check_remote(
            [
                _medication("a", "바이테롤정 10/20mg"),
                _medication("b", "이트라녹스정100mg"),
            ],
            client,
        )

    assert set(product_names) == {
        "바이테롤정 10/20mg",
        "이트라녹스정100mg",
        "바이테롤정",
        "이트라녹스정",
    }
    assert product_names.index("바이테롤정 10/20mg") < product_names.index("바이테롤정")
    assert product_names.index("이트라녹스정100mg") < product_names.index("이트라녹스정")
    assert len(result.warnings) == 1
    assert result.warnings[0].source_code == "19"
    assert result.warnings[0].message.count("횡문근융해증") == 1
    assert "근증/횡문근변성의 위험성이 증가" in result.warnings[0].message


def test_not_found_and_too_broad_become_one_drug_unverified_warnings() -> None:
    def resolve(query: MedicationQuery) -> MedicationDurLookup:
        if query.item_name_candidates[0] == "없는약":
            return _not_found(query)
        return _too_broad(query)

    result = dur._check_remote(  # type: ignore[arg-type]
        [_medication("a", "없는약"), _medication("b", "아스피린")],
        FakeClient(resolve),
    )

    assert [warning.warning_type for warning in result.warnings] == [
        "unverified",
        "unverified",
    ]
    assert [warning.medication_ids for warning in result.warnings] == [["a"], ["b"]]
    assert "찾지 못해" in result.warnings[0].message
    assert "너무 포괄적" in result.warnings[1].message


def test_existing_drugs_with_no_contraindication_rows_return_no_warning() -> None:
    def resolve(query: MedicationQuery) -> MedicationDurLookup:
        name = query.item_name_candidates[0]
        return _verified(query, _profile(name))

    result = dur._check_remote(  # type: ignore[arg-type]
        [_medication("a", "타이레놀정"), _medication("b", "아모잘탄정")],
        FakeClient(resolve),
    )
    assert result.warnings == []


def test_null_contents_use_fixed_message_and_smallest_numeric_source() -> None:
    profiles = {
        "약품에이정": _profile(
            "약품에이정",
            ingredients={"A"},
            contraindications={"B": [("100", None), ("9", None)]},
        ),
        "약품비정": _profile("약품비정", ingredients={"B"}),
    }

    def resolve(query: MedicationQuery) -> MedicationDurLookup:
        name = query.item_name_candidates[0]
        return _verified(query, profiles[name])

    result = dur._check_remote(  # type: ignore[arg-type]
        [_medication("a", "약품에이정"), _medication("b", "약품비정")],
        FakeClient(resolve),
    )
    assert result.warnings[0].source_code == "9"
    assert "함께 복용하면 안 되는 조합" in result.warnings[0].message


def test_item_sequence_uses_exact_query_and_skips_name_candidates() -> None:
    def resolve(query: MedicationQuery) -> MedicationDurLookup:
        assert query.item_seq is not None
        profile = DurProfile(
            query=DurQuery.by_item_seq(query.item_seq),
            total_count=0,
            too_broad=False,
            ingredient_codes=frozenset(),
            contraindications=(),
        )
        return _verified(query, profile)

    client = FakeClient(resolve)
    result = dur._check_remote(  # type: ignore[arg-type]
        [
            _medication("a", "무시할 이름", item_seq=" 12345 "),
            _medication("b", "다른 이름", item_seq="67890"),
        ],
        client,
    )
    assert result.warnings == []
    assert [query.item_seq for query in client.queries] == ["12345", "67890"]
    assert all(not query.item_name_candidates for query in client.queries)


def test_upstream_error_is_preserved_and_unexpected_error_is_sanitized(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingClient:
        def lookup_many(self, _queries: object) -> tuple[()]:
            raise RuntimeError("serviceKey=secret medication=private")

    monkeypatch.setattr(dur, "get_settings", lambda: SimpleNamespace(is_mock=False))
    monkeypatch.setattr(dur, "get_mfds_client", lambda: FailingClient())
    payload = DurCheckIn(
        medications=[_medication("a", "약품에이정"), _medication("b", "약품비정")]
    )

    with pytest.raises(UpstreamError) as error:
        dur.check_interactions(payload)
    assert error.value.status_code == 502
    assert error.value.code == "DUR_UPSTREAM_ERROR"
    assert "secret" not in error.value.message
    assert "private" not in error.value.message
