"""Ollama의 OpenAI 호환 엔드포인트용 AgentDojo LLM 파이프라인 요소.

agentdojo 0.1.35의 OpenAILLM을 그대로 쓰지 않는 이유:
1. 배포판에는 `openai-compatible` 프로바이더가 없다 (main 브랜치에만 존재).
2. OpenAILLM은 `temperature or NOT_GIVEN` 때문에 temperature=0.0을 실제로 보내지 않는다.
3. Qwen3 계열의 thinking 출력(`<think>...</think>`, 또는 reasoning 필드)을 제어/제거해야 한다.
4. tool_filter 방어는 llm이 OpenAILLM 인스턴스여야 하므로 OpenAILLM을 상속한다.
"""

from __future__ import annotations

import re
from collections.abc import Sequence

import openai
from openai import NOT_GIVEN
from tenacity import retry, retry_if_not_exception_type, stop_after_attempt, wait_random_exponential

from agentdojo.agent_pipeline.llms.openai_llm import (
    OpenAILLM,
    _function_to_openai,
    _message_to_openai,
    _openai_to_assistant_message,
)
from agentdojo.functions_runtime import EmptyEnv, Env, FunctionsRuntime
from agentdojo.types import ChatMessage, text_content_block_from_string

_THINK_RE = re.compile(r"<think>.*?</think>\s*", re.DOTALL)


def strip_think(text: str) -> str:
    """`<think>...</think>` 블록을 제거한다. 닫히지 않은 블록은 그대로 둔다."""
    return _THINK_RE.sub("", text)


class OllamaLLM(OpenAILLM):
    """Ollama OpenAI 호환 API를 호출하는 파이프라인 요소.

    Args:
        client: base_url이 Ollama 서버(`.../v1`)로 설정된 openai.OpenAI 클라이언트.
        model: Ollama 모델 태그 (예: `qwen3.8:27b`).
        temperature: 매 요청에 명시적으로 전송된다 (0.0 포함).
        seed: 재현성을 위한 시드. None이면 보내지 않는다.
        reasoning_effort: Ollama는 `"none"`을 think=false로 매핑한다. None이면 보내지 않는다.
        strip_thinking: 응답 content에 섞인 `<think>` 블록 제거 여부.
        max_tokens: 응답 최대 토큰(num_predict). None이면 보내지 않는다.
    """

    def __init__(
        self,
        client: openai.OpenAI,
        model: str,
        temperature: float | None = 0.0,
        seed: int | None = 0,
        reasoning_effort: str | None = "none",
        strip_thinking: bool = True,
        max_tokens: int | None = None,
    ) -> None:
        super().__init__(client, model, reasoning_effort=None, temperature=temperature)
        self.name = model
        self.seed = seed
        self.ollama_reasoning_effort = reasoning_effort
        self.strip_thinking = strip_thinking
        self.max_tokens = max_tokens

    @retry(
        wait=wait_random_exponential(multiplier=1, max=40),
        stop=stop_after_attempt(3),
        reraise=True,
        retry=retry_if_not_exception_type((openai.BadRequestError, openai.UnprocessableEntityError)),
    )
    def _request(self, openai_messages, openai_tools):
        return self.client.chat.completions.create(
            model=self.model,
            messages=openai_messages,
            tools=openai_tools or NOT_GIVEN,
            tool_choice="auto" if openai_tools else NOT_GIVEN,
            temperature=self.temperature if self.temperature is not None else NOT_GIVEN,
            seed=self.seed if self.seed is not None else NOT_GIVEN,
            reasoning_effort=self.ollama_reasoning_effort or NOT_GIVEN,  # type: ignore[arg-type]
            max_tokens=self.max_tokens or NOT_GIVEN,
        )

    def query(
        self,
        query: str,
        runtime: FunctionsRuntime,
        env: Env = EmptyEnv(),
        messages: Sequence[ChatMessage] = [],
        extra_args: dict = {},
    ) -> tuple[str, FunctionsRuntime, Env, Sequence[ChatMessage], dict]:
        openai_messages = [_message_to_openai(message, self.model) for message in messages]
        openai_tools = [_function_to_openai(tool) for tool in runtime.functions.values()]
        completion = self._request(openai_messages, openai_tools)
        output = _openai_to_assistant_message(completion.choices[0].message)
        if self.strip_thinking and output["content"]:
            cleaned = [
                text_content_block_from_string(strip_think(block["content"]))
                for block in output["content"]
                if block.get("type") == "text" and block.get("content") is not None
            ]
            output["content"] = cleaned or None
        messages = [*messages, output]
        return query, runtime, env, messages, extra_args
