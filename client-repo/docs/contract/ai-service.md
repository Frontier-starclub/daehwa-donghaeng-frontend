# AI 서비스 계약

백엔드(`frontier-starclub/daehwa-donghaeng`)와 AI 서비스 사이의 인터페이스 정의.
**이 문서와 `ai/app/schemas.py`, 백엔드 `apps/backend/app/providers.py`는 항상 같이 움직인다.**

- Base URL: `http://ai:8100` (compose 네트워크) / `http://localhost:8100` (로컬)
- 인증 없음. 백엔드만 호출하며 외부에 노출하지 않는다.
- 앱은 이 서비스를 직접 호출하지 않는다. 호출 방향은 앱 → 백엔드 → AI 서비스 단방향이다.

## 설계 원칙

응답 필드를 백엔드 `providers.py`의 dataclass와 **1:1로 맞춘다.** 백엔드 어댑터가
`RecognizedMedication(**item)` 형태로 그대로 넘길 수 있어야 하고, 그래야 어댑터가
각 30줄 이하로 끝난다. 필드 이름을 하나라도 바꾸려면 양쪽을 함께 바꾼다.

`ai/tests/test_contract.py`가 이 대응을 검사한다.

---

## `GET /health/live`

```json
{ "status": "ok", "provider_mode": "mock" }
```

compose healthcheck가 이 경로를 본다.

---

## `POST /v1/ocr/prescription-label`

약봉투 사진에서 약 정보를 추출한다. Flowchart OCR-04 노드.

**요청** — `multipart/form-data`

| 필드 | 값 |
| --- | --- |
| `image` | JPEG 또는 PNG. 원본 10MiB 이하이며 remote 모드는 base64 10MB 제한 때문에 원본 약 7.15MiB 이하 |

**응답 200** — 백엔드 `RecognizedMedication`과 동일

```json
{
  "items": [
    {
      "name": "아모잘탄정",
      "ingredient_name": null,
      "ingredient_code": null,
      "item_seq": null,
      "dose_frequency_per_day": 1,
      "confidence": 0.96
    }
  ]
}
```

약 이름만 필수다. 나머지는 인식하지 못하면 `null`로 둔다 — 추측해서 채우지 않는다.
결과는 사용자 확인(OCR-05)을 반드시 거치므로 이 단계에서 판단하지 않는다.

**오류**

| 상태 | code | 상황 |
| --- | --- | --- |
| 415 | `UNSUPPORTED_IMAGE` | JPEG/PNG가 아님 |
| 413 | `IMAGE_TOO_LARGE` | 원본 10MiB 초과 또는 remote 전송 시 base64 10MB 초과 |
| 502 | `OCR_UPSTREAM_ERROR` | 외부 API 호출 실패 |

빈 결과(`items: []`)는 오류가 아니라 200이다. 백엔드가 이를 `OCR_EMPTY`로 처리한다.

---

## `POST /v1/dur/check`

약물 상호작용 정보를 조회한다. Flowchart FC-02.

**요청**

```json
{
  "medications": [
    { "id": "uuid", "name": "아모잘탄정", "ingredient_code": null, "item_seq": null }
  ]
}
```

**응답 200** — 백엔드 `DurProviderWarning`과 동일

```json
{
  "warnings": [
    {
      "warning_type": "usjnt_taboo",
      "medication_ids": ["uuid-a", "uuid-b"],
      "message": "함께 복용할 때 주의가 필요합니다.",
      "source_code": "DUR-1234"
    }
  ]
}
```

`medication_ids`에는 **요청에서 받은 `id`를 그대로** 넣는다. 앱이 이 값으로 어떤 약이
문제인지 표시한다.

이번 릴리스에서 `warning_type`은 `usjnt_taboo`(병용금기)와 `unverified`(품목을
확인하지 못함)만 사용한다. `elderly_caution`(노인주의)과
`efficacy_overlap`(효능군중복)은 범위 밖이다. `unverified`는 해당 약의 ID 하나만
담으며, 이름 매핑이 불확실할 때 잘못된 안전 판정을 내리는 대신 확인 불가로 닫는다.

> 상담 권고 문구는 이 서비스가 내려주지 않는다. 백엔드 `DurCheckOut.disclaimer`가
> 담당하며 앱이 그 값을 렌더링한다 (회의록 결정사항 2).

**오류**

| 상태 | code | 상황 |
| --- | --- | --- |
| 502 | `DUR_UPSTREAM_ERROR` | 식약처 API 호출 실패 |

경고 없음(`warnings: []`)은 정상 200이다.

---

## `POST /v1/chat/reply`

말벗 대화 응답을 생성한다. Flowchart FC-04.

**요청**

```json
{ "opening": false, "user_message_count": 3, "content": "오늘 손주가 왔어요" }
```

`opening: true`면 `content`는 무시하고 첫 인사말을 돌려준다.

**응답 200**

```json
{ "content": "그러셨군요. 손주분과 무슨 이야기를 나누셨어요?" }
```

이 엔드포인트는 **상태를 갖지 않는다.** 세션 상태, 메시지 순서, 멱등성
(`client_message_id`)은 전부 백엔드가 관리한다.

이번 릴리스에서는 대화 이력을 AI 서비스에 전달하지 않는 단발 응답으로 동작한다.
첫 인사(`opening: true`)는 외부 모델을 호출하지 않는 고정 인사말이다. 일반 응답은
고령자 말벗 톤의 짧은 평문으로 생성하며 진단, 증상 해석, 복약 지시는 하지 않는다.
긴급 증상이나 과다복용은 119 또는 가족·의사·약사에게 즉시 연락하도록, 자해·자살
암시는 자살예방상담전화 109에 연락하도록 안내한다. 이 안전 문구와 `unverified`
사용자 문구는 현재 잠정안이며 PM 확인 후 문구를 확정한다.

음성은 앱에서 STT/TTS로 처리하므로 이 서비스는 텍스트만 다룬다
(백엔드 `docs/chat-session.md` 계약 — 음성 파일은 서버로 오지 않는다).

**오류**

| 상태 | code | 상황 |
| --- | --- | --- |
| 502 | `CHAT_UPSTREAM_ERROR` | 외부 모델 호출 또는 응답 검증 실패 |

---

## 오류 형식

모든 실패는 `{code, message}`다.

```json
{ "code": "DUR_UPSTREAM_ERROR", "message": "주의사항을 확인하지 못했습니다." }
```

백엔드 어댑터는 5xx를 `RuntimeError`로 바꾸고, 백엔드의 기존 예외 처리가 이를
`502 OCR_PROVIDER_ERROR` / `502 DUR_PROVIDER_ERROR` / `502 CHAT_PROVIDER_ERROR`로
매핑한다. 따라서 이 서비스가 **5xx를 지키는 한 백엔드 로직 수정은 필요 없다.**

---

## 관련 공공 API

- [DUR 품목정보](https://www.data.go.kr/data/15059486/openapi.do) — 병용금기·노인주의·효능군중복

품목 목록과 병용금기 조회는 같은 DUR 품목정보 서비스의
`getDurPrdlstInfoList03`과 `getUsjntTabooInfoList03`을 사용한다.
