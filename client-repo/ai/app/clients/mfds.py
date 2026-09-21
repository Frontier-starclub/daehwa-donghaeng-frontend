"""Synchronous client for the MFDS DUR product and contraindication APIs.

The public return values are deliberately small, immutable dataclasses.  Raw
MFDS rows can be several megabytes for a single medicine and must not escape
this module or be retained in the process cache.
"""

from __future__ import annotations

import logging
import math
import threading
import time
from collections import OrderedDict
from collections.abc import Callable, Iterable, Sequence
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError, as_completed
from dataclasses import dataclass
from enum import StrEnum
from functools import lru_cache
from typing import Generic, TypeVar

import httpx

from app.config import get_settings
from app.errors import UpstreamError

# httpx includes the complete query string in INFO messages.  The query string
# contains serviceKey, so keep both HTTP libraries above INFO even if the
# application enables verbose logging globally.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

_PRODUCT_OPERATION = "DURPrdlstInfoService03/getDurPrdlstInfoList03"
_CONTRAINDICATION_OPERATION = "DURPrdlstInfoService03/getUsjntTabooInfoList03"

_PAGE_SIZE = 500
_MAX_CONTRAINDICATION_ROWS = 5_000
_MAX_HTTP_CONCURRENCY = 3
_DEFAULT_DEADLINE_SECONDS = 20.0
_CACHE_TTL_SECONDS = 24 * 60 * 60
_CACHE_MAX_ENTRIES = 2_048

_CONNECT_TIMEOUT_SECONDS = 5.0
_READ_TIMEOUT_SECONDS = 10.0

_ERROR_CODE = "DUR_UPSTREAM_ERROR"
_ERROR_MESSAGE = "식약처 의약품 정보를 확인하지 못했습니다. 잠시 후 다시 시도해 주세요."


@dataclass(frozen=True, slots=True)
class MfdsDeadline:
    """Absolute deadline shared by all MFDS calls for one DUR request."""

    expires_at: float


@dataclass(frozen=True, slots=True)
class ProductLookup:
    """Result of checking whether an item name exists in the product list.

    ``item_sequences`` contains the identifiers returned on the first page.
    Existence checking does not need to download subsequent product-list pages.
    ``total_count`` still exposes how many matches MFDS reported.
    """

    item_name: str
    total_count: int
    item_sequences: tuple[str, ...]

    @property
    def exists(self) -> bool:
        return self.total_count > 0


@dataclass(frozen=True, slots=True)
class DurQuery:
    """An exact item-sequence query or a partial item-name query."""

    item_name: str | None = None
    item_seq: str | None = None

    def __post_init__(self) -> None:
        name = _strip_query(self.item_name) if self.item_name is not None else None
        sequence = _clean_query(self.item_seq) if self.item_seq is not None else None
        if (name is None) == (sequence is None):
            raise ValueError("exactly one of item_name and item_seq is required")
        object.__setattr__(self, "item_name", name)
        object.__setattr__(self, "item_seq", sequence)

    @classmethod
    def by_name(cls, item_name: str) -> DurQuery:
        return cls(item_name=item_name)

    @classmethod
    def by_item_seq(cls, item_seq: str) -> DurQuery:
        return cls(item_seq=item_seq)

    @property
    def cache_key(self) -> str:
        if self.item_seq is not None:
            return f"item-seq:{self.item_seq}"
        return f"item-name:{self.item_name}"

    def as_params(self) -> dict[str, str]:
        if self.item_seq is not None:
            return {"itemSeq": self.item_seq}
        assert self.item_name is not None
        return {"itemName": self.item_name}


@dataclass(frozen=True, slots=True)
class DurEvidence:
    """One distinct MFDS reason for a contraindicated ingredient."""

    dur_seq: str
    prohibition_content: str | None


@dataclass(frozen=True, slots=True)
class IngredientContraindications:
    """All evidence associated with one contraindicated ingredient code."""

    mixture_ingredient_code: str
    evidence: tuple[DurEvidence, ...]


@dataclass(frozen=True, slots=True)
class DurProfile:
    """Condensed contraindication data for one item query.

    A profile with ``too_broad=True`` intentionally contains no partial rows.
    It tells the router to return an ``unverified`` warning and is never cached.
    """

    query: DurQuery
    total_count: int
    too_broad: bool
    ingredient_codes: frozenset[str]
    contraindications: tuple[IngredientContraindications, ...]

    def evidence_for(self, ingredient_code: str) -> tuple[DurEvidence, ...]:
        """Return evidence for a counterpart code without exposing a mutable map."""

        for group in self.contraindications:
            if group.mixture_ingredient_code == ingredient_code:
                return group.evidence
        return ()


class MedicationLookupStatus(StrEnum):
    """Outcome of resolving and checking one medication."""

    VERIFIED = "verified"
    NOT_FOUND = "not_found"
    TOO_BROAD = "too_broad"


@dataclass(frozen=True, slots=True)
class MedicationQuery:
    """Router-ready query with either an exact id or ordered name fallbacks."""

    item_name_candidates: tuple[str, ...] = ()
    item_seq: str | None = None

    def __post_init__(self) -> None:
        sequence = _clean_query(self.item_seq) if self.item_seq is not None else None
        candidates: list[str] = []
        seen: set[str] = set()
        for candidate in self.item_name_candidates:
            cleaned = _strip_query(candidate)
            if cleaned not in seen:
                seen.add(cleaned)
                candidates.append(cleaned)
        if (sequence is None) == (not candidates):
            raise ValueError("provide either item_seq or item_name_candidates")
        object.__setattr__(self, "item_seq", sequence)
        object.__setattr__(self, "item_name_candidates", tuple(candidates))

    @classmethod
    def by_item_seq(cls, item_seq: str) -> MedicationQuery:
        return cls(item_seq=item_seq)

    @classmethod
    def by_name_candidates(cls, *candidates: str) -> MedicationQuery:
        return cls(item_name_candidates=tuple(candidates))


@dataclass(frozen=True, slots=True)
class MedicationDurLookup:
    """Existence and contraindication result for one requested medication."""

    query: MedicationQuery
    status: MedicationLookupStatus
    matched_item_name: str | None
    item_sequences: tuple[str, ...]
    profile: DurProfile | None


@dataclass(frozen=True, slots=True)
class _Page:
    total_count: int
    rows: tuple[dict[str, object], ...]


class _MfdsFailure(Exception):
    """Internal sentinel whose message never reaches an API response."""


class _DeadlineExceeded(_MfdsFailure):
    pass


K = TypeVar("K")
V = TypeVar("V")


class _TtlCache(Generic[K, V]):
    def __init__(
        self,
        *,
        ttl_seconds: float,
        max_entries: int,
        clock: Callable[[], float],
    ) -> None:
        self._ttl_seconds = ttl_seconds
        self._max_entries = max_entries
        self._clock = clock
        self._entries: OrderedDict[K, tuple[float, V]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key: K) -> V | None:
        now = self._clock()
        with self._lock:
            entry = self._entries.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if expires_at <= now:
                del self._entries[key]
                return None
            self._entries.move_to_end(key)
            return value

    def put(self, key: K, value: V) -> None:
        now = self._clock()
        with self._lock:
            expired = [
                cached_key
                for cached_key, (expires_at, _value) in self._entries.items()
                if expires_at <= now
            ]
            for cached_key in expired:
                del self._entries[cached_key]

            self._entries[key] = (now + self._ttl_seconds, value)
            self._entries.move_to_end(key)
            while len(self._entries) > self._max_entries:
                self._entries.popitem(last=False)

    def clear(self) -> None:
        with self._lock:
            self._entries.clear()


class MfdsClient:
    """Thread-safe, bounded-concurrency MFDS API client.

    Create one instance per process (``get_mfds_client`` does this for the app)
    so its 24-hour in-memory cache and connection pool are reused.  For a DUR
    endpoint invocation, call ``start_deadline`` once and pass that object to
    both product and contraindication lookups.
    """

    def __init__(
        self,
        *,
        service_key: str | None,
        base_url: str,
        transport: httpx.BaseTransport | None = None,
        clock: Callable[[], float] = time.monotonic,
        deadline_seconds: float = _DEFAULT_DEADLINE_SECONDS,
        cache_ttl_seconds: float = _CACHE_TTL_SECONDS,
    ) -> None:
        self._service_key = service_key.strip() if service_key else None
        self._clock = clock
        self._deadline_seconds = deadline_seconds
        self._configuration_valid = _is_https_url(base_url)

        normalized_base_url = (
            base_url.rstrip("/") + "/"
            if self._configuration_valid
            else "https://invalid-mfds-configuration.local/"
        )
        self._http = httpx.Client(
            base_url=normalized_base_url,
            transport=transport,
            trust_env=False,
            limits=httpx.Limits(
                max_connections=_MAX_HTTP_CONCURRENCY,
                max_keepalive_connections=_MAX_HTTP_CONCURRENCY,
            ),
            follow_redirects=False,
        )
        self._http_executor = ThreadPoolExecutor(
            max_workers=_MAX_HTTP_CONCURRENCY,
            thread_name_prefix="mfds-http",
        )
        self._product_cache: _TtlCache[str, ProductLookup] = _TtlCache(
            ttl_seconds=cache_ttl_seconds,
            max_entries=_CACHE_MAX_ENTRIES,
            clock=clock,
        )
        self._dur_cache: _TtlCache[str, DurProfile] = _TtlCache(
            ttl_seconds=cache_ttl_seconds,
            max_entries=_CACHE_MAX_ENTRIES,
            clock=clock,
        )

    def __enter__(self) -> MfdsClient:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def close(self) -> None:
        self._http_executor.shutdown(wait=True, cancel_futures=True)
        self._http.close()

    def clear_cache(self) -> None:
        """Clear both caches; useful when refreshing data or isolating tests."""

        self._product_cache.clear()
        self._dur_cache.clear()

    def start_deadline(self, seconds: float | None = None) -> MfdsDeadline:
        budget = self._deadline_seconds if seconds is None else seconds
        if budget <= 0:
            raise ValueError("deadline must be positive")
        return MfdsDeadline(expires_at=self._clock() + budget)

    def lookup_product(
        self,
        item_name: str,
        *,
        deadline: MfdsDeadline | None = None,
    ) -> ProductLookup:
        """Check an item name and return first-page ITEM_SEQ values."""

        request_deadline = deadline or self.start_deadline()
        try:
            return self._lookup_product(item_name, request_deadline)
        except UpstreamError:
            raise
        except Exception:
            raise _public_error() from None

    def lookup_products(
        self,
        item_names: Sequence[str],
        *,
        deadline: MfdsDeadline | None = None,
    ) -> tuple[ProductLookup, ...]:
        """Look up product names concurrently while preserving input order."""

        request_deadline = deadline or self.start_deadline()
        try:
            return self._run_batch(
                tuple(item_names),
                lambda item_name: self._lookup_product(item_name, request_deadline),
                request_deadline,
            )
        except UpstreamError:
            raise
        except Exception:
            raise _public_error() from None

    def lookup_contraindications(
        self,
        query: DurQuery,
        *,
        deadline: MfdsDeadline | None = None,
    ) -> DurProfile:
        """Download and condense every page for one item query."""

        request_deadline = deadline or self.start_deadline()
        try:
            return self._lookup_contraindications(query, request_deadline)
        except UpstreamError:
            raise
        except Exception:
            raise _public_error() from None

    def lookup_contraindications_many(
        self,
        queries: Sequence[DurQuery],
        *,
        deadline: MfdsDeadline | None = None,
    ) -> tuple[DurProfile, ...]:
        """Look up drugs and pages concurrently under one shared deadline."""

        request_deadline = deadline or self.start_deadline()
        try:
            return self._run_batch(
                tuple(queries),
                lambda query: self._lookup_contraindications(query, request_deadline),
                request_deadline,
            )
        except UpstreamError:
            raise
        except Exception:
            raise _public_error() from None

    def lookup_many(
        self,
        queries: Sequence[MedicationQuery],
        *,
        deadline: MfdsDeadline | None = None,
    ) -> tuple[MedicationDurLookup, ...]:
        """Resolve product-name fallbacks and fetch DUR profiles concurrently.

        Exact ``item_seq`` queries skip product-list lookup.  Name candidates
        are checked in their supplied order; only the first existing name is
        sent to the contraindication operation.
        """

        request_deadline = deadline or self.start_deadline()
        try:
            return self._run_batch(
                tuple(queries),
                lambda query: self._lookup_medication(query, request_deadline),
                request_deadline,
            )
        except UpstreamError:
            raise
        except Exception:
            raise _public_error() from None

    def _lookup_product(
        self,
        item_name: str,
        deadline: MfdsDeadline,
    ) -> ProductLookup:
        self._remaining(deadline)
        cleaned_name = _strip_query(item_name)
        cached = self._product_cache.get(cleaned_name)
        if cached is not None:
            return cached

        page = self._fetch_page(
            _PRODUCT_OPERATION,
            {"itemName": cleaned_name},
            page_number=1,
            deadline=deadline,
        )
        sequences: list[str] = []
        seen: set[str] = set()
        for row in page.rows:
            item_sequence = _required_text(row, "ITEM_SEQ")
            if item_sequence not in seen:
                seen.add(item_sequence)
                sequences.append(item_sequence)

        result = ProductLookup(
            item_name=cleaned_name,
            total_count=page.total_count,
            item_sequences=tuple(sequences),
        )
        self._remaining(deadline)
        self._product_cache.put(cleaned_name, result)
        return result

    def _lookup_contraindications(
        self,
        query: DurQuery,
        deadline: MfdsDeadline,
    ) -> DurProfile:
        self._remaining(deadline)
        cached = self._dur_cache.get(query.cache_key)
        if cached is not None:
            return cached

        first_page = self._fetch_page(
            _CONTRAINDICATION_OPERATION,
            query.as_params(),
            page_number=1,
            deadline=deadline,
        )
        total_count = first_page.total_count
        if total_count > _MAX_CONTRAINDICATION_ROWS:
            return DurProfile(
                query=query,
                total_count=total_count,
                too_broad=True,
                ingredient_codes=frozenset(),
                contraindications=(),
            )

        pages: dict[int, _Page] = {1: first_page}
        page_count = math.ceil(total_count / _PAGE_SIZE) if total_count else 1
        if page_count > 1:
            pages.update(
                self._fetch_pages(
                    _CONTRAINDICATION_OPERATION,
                    query.as_params(),
                    range(2, page_count + 1),
                    deadline,
                )
            )

        rows: list[dict[str, object]] = []
        for page_number in range(1, page_count + 1):
            page = pages[page_number]
            if page.total_count != total_count:
                raise _MfdsFailure
            rows.extend(page.rows)
        if len(rows) != total_count:
            raise _MfdsFailure

        result = _condense_profile(query, total_count, rows)
        self._remaining(deadline)
        self._dur_cache.put(query.cache_key, result)
        return result

    def _lookup_medication(
        self,
        query: MedicationQuery,
        deadline: MfdsDeadline,
    ) -> MedicationDurLookup:
        if query.item_seq is not None:
            profile = self._lookup_contraindications(
                DurQuery.by_item_seq(query.item_seq),
                deadline,
            )
            status = (
                MedicationLookupStatus.TOO_BROAD
                if profile.too_broad
                else MedicationLookupStatus.VERIFIED
            )
            return MedicationDurLookup(
                query=query,
                status=status,
                matched_item_name=None,
                item_sequences=(),
                profile=profile,
            )

        for candidate in query.item_name_candidates:
            product = self._lookup_product(candidate, deadline)
            if not product.exists:
                continue
            profile = self._lookup_contraindications(
                DurQuery.by_name(candidate),
                deadline,
            )
            status = (
                MedicationLookupStatus.TOO_BROAD
                if profile.too_broad
                else MedicationLookupStatus.VERIFIED
            )
            return MedicationDurLookup(
                query=query,
                status=status,
                matched_item_name=candidate,
                item_sequences=product.item_sequences,
                profile=profile,
            )

        return MedicationDurLookup(
            query=query,
            status=MedicationLookupStatus.NOT_FOUND,
            matched_item_name=None,
            item_sequences=(),
            profile=None,
        )

    def _fetch_page(
        self,
        operation: str,
        operation_params: dict[str, str],
        *,
        page_number: int,
        deadline: MfdsDeadline,
    ) -> _Page:
        remaining = self._remaining(deadline)
        future = self._http_executor.submit(
            self._request_page_with_retry,
            operation,
            operation_params,
            page_number,
            deadline,
        )
        try:
            return future.result(timeout=remaining)
        except TimeoutError:
            future.cancel()
            raise _DeadlineExceeded from None

    def _fetch_pages(
        self,
        operation: str,
        operation_params: dict[str, str],
        page_numbers: Iterable[int],
        deadline: MfdsDeadline,
    ) -> dict[int, _Page]:
        futures: dict[Future[_Page], int] = {
            self._http_executor.submit(
                self._request_page_with_retry,
                operation,
                operation_params,
                page_number,
                deadline,
            ): page_number
            for page_number in page_numbers
        }
        pages: dict[int, _Page] = {}
        try:
            for future in as_completed(futures, timeout=self._remaining(deadline)):
                pages[futures[future]] = future.result()
        except TimeoutError:
            raise _DeadlineExceeded from None
        finally:
            for future in futures:
                if not future.done():
                    future.cancel()
        self._remaining(deadline)
        return pages

    def _request_page_with_retry(
        self,
        operation: str,
        operation_params: dict[str, str],
        page_number: int,
        deadline: MfdsDeadline,
    ) -> _Page:
        for attempt in range(2):
            try:
                return self._request_page(
                    operation,
                    operation_params,
                    page_number,
                    deadline,
                )
            except _MfdsFailure:
                if attempt == 1:
                    raise
                self._remaining(deadline)
        raise _MfdsFailure  # pragma: no cover - the loop always returns or raises

    def _request_page(
        self,
        operation: str,
        operation_params: dict[str, str],
        page_number: int,
        deadline: MfdsDeadline,
    ) -> _Page:
        if not self._service_key or not self._configuration_valid:
            raise _MfdsFailure

        remaining = self._remaining(deadline)
        timeout = httpx.Timeout(
            connect=min(_CONNECT_TIMEOUT_SECONDS, remaining),
            read=min(_READ_TIMEOUT_SECONDS, remaining),
            write=min(_READ_TIMEOUT_SECONDS, remaining),
            pool=min(_CONNECT_TIMEOUT_SECONDS, remaining),
        )
        params = {
            "serviceKey": self._service_key,
            "type": "json",
            "numOfRows": str(_PAGE_SIZE),
            "pageNo": str(page_number),
            **operation_params,
        }
        try:
            response = self._http.get(operation, params=params, timeout=timeout)
            self._remaining(deadline)
            if not 200 <= response.status_code < 300:
                raise _MfdsFailure
            payload = response.json()
            return _parse_page(payload, expected_page=page_number)
        except _MfdsFailure:
            raise
        except Exception:
            # Do not retain or expose the httpx exception: it may contain the
            # complete URL, including serviceKey.
            raise _MfdsFailure from None

    def _run_batch(
        self,
        values: tuple[V, ...],
        function: Callable[[V], K],
        deadline: MfdsDeadline,
    ) -> tuple[K, ...]:
        if not values:
            return ()
        self._remaining(deadline)
        executor = ThreadPoolExecutor(
            max_workers=min(_MAX_HTTP_CONCURRENCY, len(values)),
            thread_name_prefix="mfds-drug",
        )
        futures = {executor.submit(function, value): index for index, value in enumerate(values)}
        results: list[K | None] = [None] * len(values)
        try:
            for future in as_completed(futures, timeout=self._remaining(deadline)):
                results[futures[future]] = future.result()
        except TimeoutError:
            raise _DeadlineExceeded from None
        finally:
            for future in futures:
                if not future.done():
                    future.cancel()
            executor.shutdown(wait=False, cancel_futures=True)

        self._remaining(deadline)
        if any(result is None for result in results):
            raise _MfdsFailure
        return tuple(result for result in results if result is not None)

    def _remaining(self, deadline: MfdsDeadline) -> float:
        remaining = deadline.expires_at - self._clock()
        if remaining <= 0:
            raise _DeadlineExceeded
        return remaining


def _clean_query(value: str | None) -> str:
    return " ".join(_strip_query(value).split())


def _strip_query(value: str | None) -> str:
    if not isinstance(value, str):
        raise ValueError("query must be a string")
    cleaned = value.strip()
    if not cleaned:
        raise ValueError("query must not be empty")
    return cleaned


def _is_https_url(value: str) -> bool:
    try:
        url = httpx.URL(value)
    except Exception:
        return False
    return url.scheme == "https" and bool(url.host)


def _parse_page(payload: object, *, expected_page: int) -> _Page:
    if not isinstance(payload, dict):
        raise _MfdsFailure
    header = payload.get("header")
    if not isinstance(header, dict) or header.get("resultCode") != "00":
        raise _MfdsFailure
    body = payload.get("body")
    if not isinstance(body, dict):
        raise _MfdsFailure

    total_count = _nonnegative_int(body.get("totalCount"))
    reported_page = body.get("pageNo")
    if reported_page is not None and _nonnegative_int(reported_page) != expected_page:
        raise _MfdsFailure

    items = body.get("items")
    if total_count == 0:
        if items not in (None, []):
            raise _MfdsFailure
        return _Page(total_count=0, rows=())

    if not isinstance(items, list) or not items or len(items) > _PAGE_SIZE:
        raise _MfdsFailure
    if not all(isinstance(item, dict) for item in items):
        raise _MfdsFailure
    if len(items) > total_count:
        raise _MfdsFailure
    return _Page(total_count=total_count, rows=tuple(items))


def _nonnegative_int(value: object) -> int:
    if isinstance(value, bool):
        raise _MfdsFailure
    if isinstance(value, int):
        parsed = value
    elif isinstance(value, str) and value.isdigit():
        parsed = int(value)
    else:
        raise _MfdsFailure
    if parsed < 0:
        raise _MfdsFailure
    return parsed


def _required_text(row: dict[str, object], key: str) -> str:
    value = row.get(key)
    if isinstance(value, int) and not isinstance(value, bool):
        value = str(value)
    if not isinstance(value, str) or not value.strip():
        raise _MfdsFailure
    return value.strip()


def _optional_text(row: dict[str, object], key: str) -> str | None:
    value = row.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise _MfdsFailure
    cleaned = value.strip()
    return cleaned or None


def _condense_profile(
    query: DurQuery,
    total_count: int,
    rows: Sequence[dict[str, object]],
) -> DurProfile:
    ingredient_codes: set[str] = set()
    evidence_by_code: dict[str, list[DurEvidence]] = {}
    seen_evidence: dict[str, set[tuple[str, str | None]]] = {}

    for row in rows:
        ingredient_code = _required_text(row, "INGR_CODE")
        mixture_code = _required_text(row, "MIXTURE_INGR_CODE")
        dur_seq = _required_text(row, "DUR_SEQ")
        content = _optional_text(row, "PROHBT_CONTENT")

        ingredient_codes.add(ingredient_code)
        evidence_key = (dur_seq, content)
        code_seen = seen_evidence.setdefault(mixture_code, set())
        if evidence_key in code_seen:
            continue
        code_seen.add(evidence_key)
        evidence_by_code.setdefault(mixture_code, []).append(
            DurEvidence(dur_seq=dur_seq, prohibition_content=content)
        )

    contraindications = tuple(
        IngredientContraindications(
            mixture_ingredient_code=code,
            evidence=tuple(evidence_by_code[code]),
        )
        for code in sorted(evidence_by_code)
    )
    return DurProfile(
        query=query,
        total_count=total_count,
        too_broad=False,
        ingredient_codes=frozenset(ingredient_codes),
        contraindications=contraindications,
    )


def _public_error() -> UpstreamError:
    return UpstreamError(_ERROR_CODE, _ERROR_MESSAGE)


@lru_cache(maxsize=1)
def get_mfds_client() -> MfdsClient:
    """Return the process-wide client used by the DUR router."""

    settings = get_settings()
    return MfdsClient(
        service_key=settings.data_go_kr_service_key,
        base_url=settings.mfds_base_url,
    )
