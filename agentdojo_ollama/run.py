"""AgentDojo 벤치마크를 Ollama 모델로 실행하는 CLI.

`python -m agentdojo.scripts.benchmark`와 옵션을 최대한 맞췄고, 모델 선택 부분만
OllamaLLM으로 대체했다. 결과 로그 형식과 디렉터리 구조는 원본과 동일하다:
    <logdir>/<model>[-<defense>]/<suite>/<user_task>/<attack|none>/<injection_task|none>.json
"""

from __future__ import annotations

import importlib
import os
import warnings
from itertools import repeat
from multiprocessing import Pool
from pathlib import Path

import click
import openai
from dotenv import load_dotenv

from agentdojo.agent_pipeline.agent_pipeline import DEFENSES, AgentPipeline, PipelineConfig
from agentdojo.attacks.attack_registry import ATTACKS, load_attack
from agentdojo.benchmark import SuiteResults, benchmark_suite_with_injections, benchmark_suite_without_injections
from agentdojo.logging import OutputLogger
from agentdojo.models import MODEL_NAMES
from agentdojo.task_suite.load_suites import get_suite, get_suites

from agentdojo_ollama.compat import detect_bench
from agentdojo_ollama.llm import OllamaLLM

NO_THINK_SUFFIX = " /no_think"
BENCH = detect_bench()


def build_pipeline(
    base_url: str,
    api_key: str,
    model: str,
    prose_name: str,
    defense: str | None,
    system_message_name: str | None,
    system_message: str | None,
    temperature: float | None,
    seed: int | None,
    reasoning_effort: str | None,
    no_think_tag: bool,
    strip_thinking: bool,
    max_tokens: int | None,
    timeout: float,
) -> AgentPipeline:
    # 공격 클래스가 pipeline.name에서 모델의 "산문 이름"을 찾으므로 등록해 둔다.
    MODEL_NAMES.setdefault(model, prose_name)

    client = openai.OpenAI(base_url=base_url, api_key=api_key, timeout=timeout, max_retries=2)
    llm = OllamaLLM(
        client,
        model,
        temperature=temperature,
        seed=seed,
        reasoning_effort=reasoning_effort,
        strip_thinking=strip_thinking,
        max_tokens=max_tokens,
    )
    config = PipelineConfig(
        llm=llm,
        model_id=model,
        defense=defense,
        system_message_name=system_message_name,
        system_message=system_message,
    )
    if no_think_tag:
        assert config.system_message is not None
        config.system_message = config.system_message.rstrip() + NO_THINK_SUFFIX
    return AgentPipeline.from_config(config)


def benchmark_suite(
    suite_name: str,
    benchmark_version: str,
    logdir: Path,
    force_rerun: bool,
    user_tasks: tuple[str, ...],
    injection_tasks: tuple[str, ...],
    attack: str | None,
    pipeline_kwargs: dict,
) -> SuiteResults:
    suite = get_suite(benchmark_version, suite_name)
    pipeline = build_pipeline(**pipeline_kwargs)
    print(f"Running suite '{suite_name}' with pipeline '{pipeline.name}' (attack={attack})")
    with OutputLogger(str(logdir)):
        if attack is None:
            return benchmark_suite_without_injections(
                pipeline,
                suite,
                user_tasks=user_tasks or None,
                logdir=logdir,
                force_rerun=force_rerun,
                benchmark_version=benchmark_version,
            )
        attacker = load_attack(attack, suite, pipeline)
        return benchmark_suite_with_injections(
            pipeline,
            suite,
            attacker,
            user_tasks=user_tasks or None,
            injection_tasks=injection_tasks or None,
            logdir=logdir,
            force_rerun=force_rerun,
            benchmark_version=benchmark_version,
        )


def show_results(suite_name: str, results: SuiteResults, with_attack: bool) -> None:
    utility = list(results["utility_results"].values())
    print(f"\n== {suite_name} ==")
    if utility:
        print(f"Utility{' under attack' if with_attack else ''}: {sum(utility) / len(utility) * 100:.2f}% ({len(utility)} cases)")
    if with_attack:
        inj = results["injection_tasks_utility_results"]
        if inj:
            print(f"Injection tasks solvable as user tasks: {sum(inj.values())}/{len(inj)}")
        security = list(results["security_results"].values())
        if security:
            print(f"Targeted ASR: {sum(security) / len(security) * 100:.2f}% ({len(security)} cases)")


@click.command()
@click.option("--base-url", envvar="OLLAMA_BASE_URL", default="http://localhost:11434/v1", show_default=True, help="Ollama OpenAI 호환 엔드포인트 (…/v1).")
@click.option("--api-key", envvar="OLLAMA_API_KEY", default="ollama", show_default=True)
@click.option("--model", envvar="OLLAMA_MODEL", required=True, help="Ollama 모델 태그, 예: qwen3.8:27b")
@click.option("--prose-name", envvar="MODEL_PROSE_NAME", default="Qwen", show_default=True, help="공격 문구에서 모델을 지칭하는 이름.")
@click.option("--benchmark-version", default="v1.2.2", show_default=True)
@click.option("--logdir", type=Path, default=Path("./runs"), show_default=True)
@click.option("--attack", type=click.Choice(sorted(ATTACKS)), default=None, help="None이면 공격 없음.")
@click.option("--defense", type=click.Choice(DEFENSES), default=None)
@click.option("--system-message-name", default=None)
@click.option("--system-message", default=None)
@click.option("--user-task", "-ut", "user_tasks", multiple=True)
@click.option("--injection-task", "-it", "injection_tasks", multiple=True)
@click.option("--suite", "-s", "suites", multiple=True, help="미지정 시 전체 suite.")
@click.option("--max-workers", default=1, show_default=True, help="suite 단위 병렬 프로세스 수 (최대 = suite 수).")
@click.option("--force-rerun", "-f", is_flag=True)
@click.option("--module-to-load", "-ml", "modules_to_load", multiple=True)
@click.option("--temperature", type=float, default=0.0, show_default=True)
@click.option("--seed", type=int, default=0, show_default=True, help="음수면 보내지 않음.")
@click.option("--reasoning-effort", default="none", show_default=True, help='Ollama: "none"=thinking off. 빈 문자열이면 보내지 않음 (모델 기본값).')
@click.option("--no-think-tag/--no-no-think-tag", default=True, show_default=True, help="시스템 메시지 끝에 Qwen3 soft switch `/no_think` 추가.")
@click.option("--strip-thinking/--keep-thinking", default=True, show_default=True, help="응답 content의 <think> 블록 제거.")
@click.option("--max-tokens", type=int, default=None, help="응답 최대 토큰(num_predict).")
@click.option("--timeout", type=float, default=600.0, show_default=True, help="요청당 타임아웃(초). 27B 모델은 넉넉히.")
@click.option("--autodojo-cache", type=click.Path(exists=True, dir_okay=False), default=None, help="[AutoDojo] --attack autodojo 에 쓸 injections.json (AUTODOJO_CACHE).")
@click.option("--autodojo-variant", type=int, default=None, help="[AutoDojo] 캐시의 변형 인덱스 (AUTODOJO_VARIANT, 기본 0).")
def main(
    base_url: str,
    api_key: str,
    model: str,
    prose_name: str,
    benchmark_version: str,
    logdir: Path,
    attack: str | None,
    defense: str | None,
    system_message_name: str | None,
    system_message: str | None,
    user_tasks: tuple[str, ...],
    injection_tasks: tuple[str, ...],
    suites: tuple[str, ...],
    max_workers: int,
    force_rerun: bool,
    modules_to_load: tuple[str, ...],
    temperature: float,
    seed: int,
    reasoning_effort: str,
    no_think_tag: bool,
    strip_thinking: bool,
    max_tokens: int | None,
    timeout: float,
    autodojo_cache: str | None,
    autodojo_variant: int | None,
) -> None:
    for module in modules_to_load:
        importlib.import_module(module)

    if autodojo_cache:
        os.environ["AUTODOJO_CACHE"] = str(Path(autodojo_cache).resolve())
    if autodojo_variant is not None:
        os.environ["AUTODOJO_VARIANT"] = str(autodojo_variant)
    if attack == "autodojo" and not os.environ.get("AUTODOJO_CACHE"):
        raise click.UsageError("--attack autodojo 에는 --autodojo-cache (또는 AUTODOJO_CACHE) 가 필요합니다.")

    if not suites:
        suites = tuple(get_suites(benchmark_version).keys())
    if len(suites) != 1 and user_tasks:
        raise click.UsageError("--user-task는 suite가 하나일 때만 지정할 수 있습니다.")

    pipeline_kwargs = dict(
        base_url=base_url,
        api_key=api_key,
        model=model,
        prose_name=prose_name,
        defense=defense,
        system_message_name=system_message_name,
        system_message=system_message,
        temperature=temperature,
        seed=None if seed < 0 else seed,
        reasoning_effort=reasoning_effort or None,
        no_think_tag=no_think_tag,
        strip_thinking=strip_thinking,
        max_tokens=max_tokens,
        timeout=timeout,
    )
    print(f"Bench: {BENCH} | Model: {model} @ {base_url} | suites: {', '.join(suites)} | attack: {attack} | defense: {defense}")

    if max_workers <= 1:
        results = {
            s: benchmark_suite(s, benchmark_version, logdir, force_rerun, user_tasks, injection_tasks, attack, pipeline_kwargs)
            for s in suites
        }
    else:
        with Pool(min(max_workers, len(suites))) as p:
            out = p.starmap(
                benchmark_suite,
                zip(
                    suites,
                    repeat(benchmark_version),
                    repeat(logdir),
                    repeat(force_rerun),
                    repeat(user_tasks),
                    repeat(injection_tasks),
                    repeat(attack),
                    repeat(pipeline_kwargs),
                ),
            )
        results = dict(zip(suites, out))

    combined = SuiteResults(utility_results={}, security_results={}, injection_tasks_utility_results={})
    for suite_name, result in results.items():
        show_results(suite_name, result, attack is not None)
        for (ut, it), v in result["utility_results"].items():
            combined["utility_results"][(f"{suite_name}_{ut}", it)] = v
        for (ut, it), v in result["security_results"].items():
            combined["security_results"][(f"{suite_name}_{ut}", it)] = v
        for it, v in result["injection_tasks_utility_results"].items():
            combined["injection_tasks_utility_results"][f"{suite_name}_{it}"] = v
    if len(results) > 1:
        show_results("combined", combined, attack is not None)


def cli() -> None:
    """엔트리포인트. click이 envvar 기본값을 읽기 전에 .env를 먼저 로드한다."""
    if not load_dotenv(".env"):
        warnings.warn("No .env file found; using CLI options / environment variables only")
    main()


if __name__ == "__main__":
    cli()
