"""AgentVigil / IterInject 가 공유하는 부품: 케이스 1회 실행, 보조 LLM, 캐시 I/O, 공통 CLI 옵션."""

from __future__ import annotations

import json
import os
import random
import re
import tempfile
import warnings
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import click
import openai
from openai import NOT_GIVEN
from tenacity import retry, retry_if_not_exception_type, stop_after_attempt, wait_random_exponential

from agentdojo.agent_pipeline.base_pipeline_element import BasePipelineElement
from agentdojo.agent_pipeline.errors import AbortAgentError
from agentdojo.base_tasks import BaseInjectionTask, BaseUserTask
from agentdojo.functions_runtime import FunctionCall, FunctionsRuntime
from agentdojo.task_suite.task_suite import (
    TaskSuite,
    functions_stack_trace_from_messages,
    model_output_from_messages,
)
from agentdojo.types import ChatMessage, get_text_content_as_str

from agentdojo_ollama.llm import strip_think

# FixedJailbreakAttack 과 같은 자리표시자. 템플릿에는 {goal} 이 반드시 있어야 한다.
TEMPLATE_FIELDS = ("goal", "user", "model", "task")
DEFAULT_USER_NAME = "Emma Johnson"


# ---------------------------------------------------------------- 케이스 실행


@dataclass
class CaseResult:
    utility: bool
    security: bool
    messages: list[ChatMessage]
    tool_calls: list[FunctionCall]
    final_text: str
    error: str | None = None

    def assistant_texts(self) -> list[str]:
        out = []
        for m in self.messages:
            if m["role"] == "assistant" and m.get("content"):
                out.append(get_text_content_as_str(m["content"]))
        return out


def run_case(
    pipeline: BasePipelineElement,
    suite: TaskSuite,
    user_task: BaseUserTask,
    injection_task: BaseInjectionTask,
    injections: dict[str, str],
) -> CaseResult:
    """`TaskSuite.run_task_with_pipeline` 과 같은 절차로 한 케이스를 실행하되, 진단에 필요한
    메시지/툴 호출 트레이스를 함께 돌려준다. 로그 파일은 남기지 않는다 (최적화 질의는 벤치마크가 아님)."""
    environment = suite.load_and_inject_default_environment(injections)
    task_environment = user_task.init_environment(environment)
    pre_environment = task_environment.model_copy(deep=True)
    runtime = FunctionsRuntime(suite.tools)
    model_output = None
    messages: list[ChatMessage] = []
    error = None
    for _ in range(3):
        try:
            _, _, task_environment, messages, _ = pipeline.query(user_task.PROMPT, runtime, task_environment)
        except AbortAgentError as e:
            task_environment = e.task_environment
            messages = list(e.messages)
        except (openai.BadRequestError, openai.UnprocessableEntityError) as e:
            # 컨텍스트 초과 등. 벤치마크 코드는 이 경우 security=True 로 처리하지만 최적화에서는 실패로 본다.
            error = repr(e)
            break
        try:
            model_output = model_output_from_messages(messages)
        except (ValueError, IndexError):
            model_output = None
        if model_output is not None:
            break
    if model_output is None and error is None:
        warnings.warn(f"Model output was None for task {user_task.ID}")
    trace = functions_stack_trace_from_messages(messages)
    utility = suite._check_task_result(user_task, model_output or [], pre_environment, task_environment, trace)
    security = suite._check_task_result(injection_task, model_output or [], pre_environment, task_environment, trace)
    final_text = get_text_content_as_str(model_output) if model_output else ""
    return CaseResult(bool(utility), bool(security), list(messages), list(trace), final_text, error)


def ground_truth_functions(suite: TaskSuite, task: BaseUserTask | BaseInjectionTask) -> list[str]:
    """태스크 정답 툴 호출의 함수 이름 목록 (순서 유지, 중복 제거)."""
    env = suite.load_and_inject_default_environment({})
    if isinstance(task, BaseUserTask):
        env = task.init_environment(env)
    try:
        calls = task.ground_truth(env)
    except Exception:  # 일부 포크 태스크는 기본 환경에서 ground_truth 가 실패할 수 있다
        return []
    seen: list[str] = []
    for c in calls:
        if c.function not in seen:
            seen.append(c.function)
    return seen


# ---------------------------------------------------------------- 템플릿 유틸


def sanitize_injection(text: str) -> str:
    """인젝션 문자열을 AgentDojo environment.yaml 에 안전하게 넣을 수 있게 다듬는다.

    인젝션은 큰따옴표 YAML 스칼라 안에 `str.format` 으로 그대로 치환되므로:
    - 백슬래시와 큰따옴표를 이스케이프해야 스칼라가 깨지지 않는다 (PyYAML 이 `\\"`→`"` 로 복원).
    - `---` / `...` 가 (스칼라 줄바꿈 뒤) 0열에 오면 문서 구분자로 오인되므로 한 칸 들여 0열을 피한다.
    LLM 이 만든 문구가 이런 시퀀스를 포함할 수 있어 재생·최적화 양쪽에서 호출한다."""
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    out = []
    for line in text.split("\n"):
        s = line.strip()
        if len(s) >= 3 and (set(s) == {"-"} or set(s) == {"."}):
            line = " " + line  # 0열의 YAML 문서 마커 회피
        out.append(line)
    return "\n".join(out)


class _SafeDict(dict):
    def __missing__(self, key: str) -> str:
        return "{" + key + "}"


def render_template(template: str, **fields: str) -> str:
    """{goal}/{user}/{model}/{task} 만 치환하고 그 외 중괄호는 그대로 둔다."""
    return template.format_map(_SafeDict(**fields))


_BRACE_RE = re.compile(r"\{(\w+)\}")


def normalize_template(text: str) -> str | None:
    """LLM 이 만든 템플릿을 정리한다. {goal} 이 없으면 None. 알 수 없는 {x} 자리표시자는 {{x}} 로 이스케이프."""
    text = strip_think(text).strip()
    text = _strip_code_fence(text)
    if "{goal}" not in text:
        return None

    def esc(m: re.Match) -> str:
        return m.group(0) if m.group(1) in TEMPLATE_FIELDS else "{{" + m.group(1) + "}}"

    text = _BRACE_RE.sub(esc, text)
    try:
        render_template(text, goal="g", user="u", model="m", task="t")
    except (ValueError, IndexError, KeyError):
        return None
    return text


def _strip_code_fence(text: str) -> str:
    m = re.match(r"^```[a-zA-Z]*\n(.*?)\n```$", text.strip(), re.DOTALL)
    return m.group(1) if m else text


# ---------------------------------------------------------------- 보조(공격자) LLM


class HelperLLM:
    """텍스트 생성용 Ollama(OpenAI 호환) 클라이언트. 변이/최적화/합성 프롬프트에 쓴다."""

    def __init__(
        self,
        base_url: str,
        api_key: str,
        model: str,
        temperature: float = 0.7,
        reasoning_effort: str | None = None,
        timeout: float = 600.0,
        max_tokens: int | None = None,
        seed: int | None = None,
    ) -> None:
        self.client = openai.OpenAI(base_url=base_url, api_key=api_key, timeout=timeout, max_retries=2)
        self.model = model
        self.temperature = temperature
        self.reasoning_effort = reasoning_effort
        self.max_tokens = max_tokens
        self.seed = seed
        self.calls = 0

    @retry(
        wait=wait_random_exponential(multiplier=1, max=40),
        stop=stop_after_attempt(3),
        reraise=True,
        retry=retry_if_not_exception_type((openai.BadRequestError, openai.UnprocessableEntityError)),
    )
    def complete(self, system: str, user: str, seed_offset: int = 0) -> str:
        self.calls += 1
        r = self.client.chat.completions.create(
            model=self.model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            temperature=self.temperature,
            reasoning_effort=self.reasoning_effort or NOT_GIVEN,  # type: ignore[arg-type]
            max_tokens=self.max_tokens or NOT_GIVEN,
            seed=(self.seed + seed_offset) if self.seed is not None else NOT_GIVEN,
        )
        content = r.choices[0].message.content or ""
        return strip_think(content).strip()

    def complete_json(self, system: str, user: str, seed_offset: int = 0) -> dict[str, Any] | None:
        text = self.complete(system, user, seed_offset)
        text = _strip_code_fence(text)
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if not m:
            return None
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            return None
        return obj if isinstance(obj, dict) else None


# ---------------------------------------------------------------- 캐시 I/O


def save_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def load_json(path: Path) -> Any:
    with path.open() as f:
        return json.load(f)


# ---------------------------------------------------------------- 태스크 샘플링


def sample_ids(ids: list[str], frac: float, max_n: int | None, rng: random.Random, explicit: tuple[str, ...]) -> list[str]:
    """명시 목록 > (frac, max_n) 샘플. frac=1, max_n=None 이면 전체."""
    if explicit:
        missing = [i for i in explicit if i not in ids]
        if missing:
            raise click.UsageError(f"unknown task ids: {missing}")
        return list(explicit)
    n = len(ids)
    if frac < 1.0:
        n = max(1, round(len(ids) * frac))
    if max_n is not None:
        n = min(n, max_n)
    if n >= len(ids):
        return list(ids)
    return sorted(rng.sample(ids, n), key=ids.index)


# ---------------------------------------------------------------- 공통 CLI 옵션


def target_options(f: Callable) -> Callable:
    """agentdojo-ollama 러너와 같은 타깃 옵션. 같은 env 변수를 읽는다."""
    opts = [
        click.option("--base-url", envvar="OLLAMA_BASE_URL", default="http://localhost:11434/v1", show_default=True),
        click.option("--api-key", envvar="OLLAMA_API_KEY", default="ollama", show_default=True),
        click.option("--model", envvar="OLLAMA_MODEL", required=True, help="타깃 Ollama 모델 태그."),
        click.option("--prose-name", envvar="MODEL_PROSE_NAME", default="Qwen", show_default=True),
        click.option("--benchmark-version", default="v1.2.2", show_default=True),
        click.option("--defense", default=None, help="타깃 방어 (기본 없음)."),
        click.option("--temperature", type=float, default=0.0, show_default=True),
        click.option("--seed", type=int, default=0, show_default=True, help="타깃 시드. 음수면 보내지 않음."),
        click.option("--reasoning-effort", default="none", show_default=True, help='타깃 thinking. "none"=off, ""=모델 기본.'),
        click.option("--no-think-tag/--no-no-think-tag", default=True, show_default=True),
        click.option("--max-tokens", type=int, default=None),
        click.option("--timeout", type=float, default=600.0, show_default=True),
        # 보조(공격자) LLM
        click.option("--helper-model", envvar="HELPER_MODEL", default=None, help="보조 LLM 태그. 기본 = 타깃과 같은 모델."),
        click.option("--helper-base-url", envvar="HELPER_BASE_URL", default=None, help="기본 = 타깃 base-url."),
        click.option("--helper-api-key", envvar="HELPER_API_KEY", default=None),
        click.option("--helper-temperature", type=float, default=0.7, show_default=True),
        click.option("--helper-reasoning-effort", envvar="HELPER_REASONING_EFFORT", default="", help='빈 값=모델 기본(thinking on). "none"=off.'),
        click.option("--helper-max-tokens", type=int, default=None),
    ]
    for o in reversed(opts):
        f = o(f)
    return f


@dataclass
class TargetConfig:
    base_url: str
    api_key: str
    model: str
    prose_name: str
    benchmark_version: str
    defense: str | None
    temperature: float
    seed: int
    reasoning_effort: str
    no_think_tag: bool
    max_tokens: int | None
    timeout: float
    helper_model: str | None
    helper_base_url: str | None
    helper_api_key: str | None
    helper_temperature: float
    helper_reasoning_effort: str
    helper_max_tokens: int | None
    extra: dict = field(default_factory=dict)

    @classmethod
    def from_kwargs(cls, kw: dict) -> "TargetConfig":
        names = {f for f in cls.__dataclass_fields__ if f != "extra"}
        return cls(**{k: kw.pop(k) for k in list(kw) if k in names}, extra=kw)

    def build_pipeline(self) -> BasePipelineElement:
        from agentdojo_ollama.run import build_pipeline  # 순환 import 방지

        return build_pipeline(
            base_url=self.base_url,
            api_key=self.api_key,
            model=self.model,
            prose_name=self.prose_name,
            defense=self.defense,
            system_message_name=None,
            system_message=None,
            temperature=self.temperature,
            seed=None if self.seed < 0 else self.seed,
            reasoning_effort=self.reasoning_effort or None,
            no_think_tag=self.no_think_tag,
            strip_thinking=True,
            max_tokens=self.max_tokens,
            timeout=self.timeout,
        )

    def build_helper(self, seed: int | None) -> HelperLLM:
        return HelperLLM(
            base_url=self.helper_base_url or self.base_url,
            api_key=self.helper_api_key or self.api_key,
            model=self.helper_model or self.model,
            temperature=self.helper_temperature,
            reasoning_effort=self.helper_reasoning_effort or None,
            timeout=self.timeout,
            max_tokens=self.helper_max_tokens,
            seed=seed,
        )

    def describe(self) -> str:
        return (
            f"target={self.model} @ {self.base_url} defense={self.defense or 'none'} | "
            f"helper={self.helper_model or self.model} @ {self.helper_base_url or self.base_url} "
            f"(temp={self.helper_temperature}, reasoning={self.helper_reasoning_effort or 'default'})"
        )
