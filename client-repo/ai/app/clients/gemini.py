"""Stateless Gemini Interactions v1 requests using the existing HTTP dependency.

Contract: https://ai.google.dev/api/interactions-api-v1
Only completed model text is consumed. Thoughts, incomplete output and tool calls
are never presented as a successful result. Routers validate the task's schema.
"""

from dataclasses import dataclass
from typing import Any

import httpx
from pydantic import BaseModel

API_URL = "https://generativelanguage.googleapis.com/v1/interactions"
TIMEOUT = httpx.Timeout(25.0, connect=5.0)


@dataclass(frozen=True)
class GeminiRequest:
    model: str
    system: str
    inputs: list[dict[str, Any]]
    max_output_tokens: int = 16_000
    schema: type[BaseModel] | None = None

    def body(self) -> dict[str, Any]:
        if not self.model.strip():
            raise ValueError("Gemini model is not configured")
        body = {
            "model": self.model,
            "system_instruction": self.system,
            "input": self.inputs,
            # Backend owns the session. Do not create retrievable Google interactions.
            "store": False,
            "stream": False,
            "generation_config": {
                "max_output_tokens": self.max_output_tokens,
                "thinking_level": "low",
            },
        }
        if self.schema is not None:
            body["response_format"] = {
                "type": "text",
                "mime_type": "application/json",
                "schema": self.schema.model_json_schema(),
            }
        return body


def text_step(text: str, *, assistant: bool = False) -> dict[str, Any]:
    return {
        "type": "model_output" if assistant else "user_input",
        "content": [{"type": "text", "text": text}],
    }


def _extract_text(response: httpx.Response) -> str:
    response.raise_for_status()
    data = response.json()
    if not isinstance(data, dict) or data.get("status") != "completed" or data.get("error"):
        raise ValueError("Gemini response did not complete")
    steps = data.get("steps")
    if not isinstance(steps, list):
        raise ValueError("Gemini response has no steps")
    texts = []
    for step in steps:
        if not isinstance(step, dict):
            raise ValueError("Invalid Gemini step")
        if step.get("type") == "thought":
            continue
        if step.get("type") != "model_output" or not isinstance(step.get("content"), list):
            raise ValueError("Unexpected Gemini output")
        for block in step["content"]:
            if not isinstance(block, dict) or block.get("type") != "text":
                raise ValueError("Unexpected Gemini content")
            text = block.get("text")
            if not isinstance(text, str):
                raise ValueError("Invalid Gemini text")
            texts.append(text)
    result = "".join(texts).strip()
    if not result:
        raise ValueError("Gemini response has no text")
    return result


class GeminiClient:
    def __init__(
        self,
        api_key: str | None,
        *,
        transport: httpx.MockTransport | None = None,
    ) -> None:
        if not api_key or not api_key.strip():
            raise ValueError("GEMINI_API_KEY is not configured")
        self._headers = {"x-goog-api-key": api_key.strip()}
        # Injection is test-only; production always uses the fixed HTTPS endpoint.
        self._transport = transport

    def generate(self, request: GeminiRequest) -> str:
        with httpx.Client(
            headers=self._headers,
            timeout=TIMEOUT,
            transport=self._transport,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            return _extract_text(client.post(API_URL, json=request.body()))

    async def generate_async(self, request: GeminiRequest) -> str:
        async with httpx.AsyncClient(
            headers=self._headers,
            timeout=TIMEOUT,
            transport=self._transport,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            return _extract_text(await client.post(API_URL, json=request.body()))
