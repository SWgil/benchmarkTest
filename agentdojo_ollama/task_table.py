"""attack type과 suite를 지정하면 모든 user task × injection task 쌍의 공격 성공 / utility 성공 표를
Markdown으로 만든다.

`summarize.py`는 (pipeline, attack, suite) 단위 비율만, `compare_attacks.py`는 공격 *간* 차이와
행동 분류를 보여 준다. 이 스크립트는 공격 하나·suite 하나를 골라 케이스 하나하나의 결과를
그대로 격자로 펼친다. agentdojo 패키지는 import하지 않으므로 venv 밖에서도 돈다.

로그 구조 (agentdojo TraceLogger):
    <logdir>/<pipeline>/<suite>/<user_task>/<attack>/<injection_task>.json   # 공격 케이스
    <logdir>/<pipeline>/<suite>/<injection_task>/<attack>/none.json          # injection task를 유저 태스크로 직접 실행
각 JSON의 security(bool)가 공격 성공, utility(bool)가 유저 태스크 성공이다.

출력 표:
  1. 공격 성공 격자  — user task(행) × injection task(열), security=True 이면 ✓
  2. utility 성공 격자 — 같은 격자, utility=True 이면 ✓
  3. 케이스 목록       — (user task, injection task, 공격 성공, utility 성공, error) 전체 행
  4. injection task 단독 실행 utility — 로그가 있을 때만
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import click


@dataclass(frozen=True)
class Case:
    pipeline: str
    suite: str
    user_task: str
    attack: str
    injection_task: str
    utility: bool
    security: bool
    error: str | None


@dataclass(frozen=True)
class InjectionAlone:
    """injection task를 유저 태스크로 직접 실행한 결과 (<suite>/<injection_task>/<attack>/none.json)."""

    pipeline: str
    suite: str
    attack: str
    injection_task: str
    utility: bool
    error: str | None


# ---------------------------------------------------------------------------
# 로그 읽기
# ---------------------------------------------------------------------------


def _read(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        print(f"skip (invalid json): {path}", file=sys.stderr)
        return None


def scan(logdir: Path, suite: str, attack: str) -> tuple[list[Case], list[InjectionAlone], set[tuple[str, str]]]:
    """suite/attack에 맞는 케이스를 모은다. 세 번째 반환값은 logdir에 있는 (suite, attack) 전체 집합 (오류 안내용)."""
    cases: list[Case] = []
    alone: list[InjectionAlone] = []
    seen: set[tuple[str, str]] = set()
    for path in sorted(logdir.rglob("*.json")):
        parts = path.relative_to(logdir).parts
        if len(parts) < 5:
            continue
        pipeline = "/".join(parts[:-4])
        p_suite, task_dir, p_attack = parts[-4:-1]
        if not task_dir.startswith(("user_task", "injection_task")):
            continue
        if not (path.name == "none.json" or path.stem.startswith("injection_task")):
            continue
        if p_attack == "none":
            continue  # 공격 없는 유틸리티 실행은 summarize.py 영역
        seen.add((p_suite, p_attack))
        if p_suite != suite or p_attack != attack:
            continue
        rec = _read(path)
        if rec is None:
            continue
        if task_dir.startswith("user_task") and path.stem.startswith("injection_task"):
            cases.append(
                Case(
                    pipeline=pipeline,
                    suite=p_suite,
                    user_task=task_dir,
                    attack=p_attack,
                    injection_task=path.stem,
                    utility=bool(rec.get("utility")),
                    security=bool(rec.get("security")),
                    error=rec.get("error"),
                )
            )
        elif task_dir.startswith("injection_task") and path.name == "none.json":
            alone.append(
                InjectionAlone(
                    pipeline=pipeline,
                    suite=p_suite,
                    attack=p_attack,
                    injection_task=task_dir,
                    utility=bool(rec.get("utility")),
                    error=rec.get("error"),
                )
            )
    return cases, alone, seen


# ---------------------------------------------------------------------------
# 표 렌더링
# ---------------------------------------------------------------------------


def _task_num(task_id: str) -> int:
    try:
        return int(task_id.rsplit("_", 1)[1])
    except (IndexError, ValueError):
        return 0


def _short(task_id: str) -> str:
    return task_id.replace("user_task_", "UT").replace("injection_task_", "IT")


def _pct(k: int, n: int) -> str:
    return f"{k / n * 100:.1f}%" if n else "-"


def _mark(c: Case | None, field: str) -> str:
    if c is None:
        return " "
    if c.error is not None:
        return "!"
    return "✓" if getattr(c, field) else "✗"


def render_grid(cases: list[Case], field: str, total_label: str) -> list[str]:
    """field='security' 면 공격 성공 격자, 'utility' 면 utility 성공 격자."""
    uts = sorted({c.user_task for c in cases}, key=_task_num)
    its = sorted({c.injection_task for c in cases}, key=_task_num)
    idx = {(c.user_task, c.injection_task): c for c in cases}
    lines = [
        f"| user task | {' | '.join(_short(i) for i in its)} | 성공/케이스 | {total_label} |",
        "|---|" + "---|" * len(its) + "---:|---:|",
    ]
    for ut in uts:
        row = [idx.get((ut, it)) for it in its]
        present = [c for c in row if c is not None]
        ok = sum(getattr(c, field) for c in present)
        cells = " | ".join(_mark(c, field) for c in row)
        lines.append(f"| {_short(ut)} | {cells} | {ok}/{len(present)} | {_pct(ok, len(present))} |")
    col_pcts = []
    for it in its:
        col = [c for c in cases if c.injection_task == it]
        col_pcts.append(_pct(sum(getattr(c, field) for c in col), len(col)))
    tot_ok = sum(getattr(c, field) for c in cases)
    lines.append(f"| **all** | {' | '.join(col_pcts)} | {tot_ok}/{len(cases)} | {_pct(tot_ok, len(cases))} |")
    return lines


def render_cases(cases: list[Case]) -> list[str]:
    lines = [
        "| user task | injection task | 공격 성공 | utility 성공 | error |",
        "|---|---|:-:|:-:|---|",
    ]
    for c in sorted(cases, key=lambda c: (_task_num(c.user_task), _task_num(c.injection_task))):
        err = c.error.replace("|", "\\|").replace("\n", " ")[:80] if c.error else ""
        lines.append(f"| {c.user_task} | {c.injection_task} | {'✓' if c.security else '✗'} | {'✓' if c.utility else '✗'} | {err} |")
    return lines


def render_alone(alone: list[InjectionAlone]) -> list[str]:
    lines = [
        "| injection task | utility 성공 | error |",
        "|---|:-:|---|",
    ]
    for a in sorted(alone, key=lambda a: _task_num(a.injection_task)):
        err = a.error.replace("|", "\\|").replace("\n", " ")[:80] if a.error else ""
        mark = "!" if a.error is not None else ("✓" if a.utility else "✗")
        lines.append(f"| {a.injection_task} | {mark} | {err} |")
    ok = sum(a.utility for a in alone)
    lines.append(f"| **all** | {ok}/{len(alone)} ({_pct(ok, len(alone))}) | |")
    return lines


def render_markdown(suite: str, attack: str, logdir: Path, cases: list[Case], alone: list[InjectionAlone]) -> str:
    by_pipeline: dict[str, list[Case]] = defaultdict(list)
    for c in cases:
        by_pipeline[c.pipeline].append(c)
    alone_by_pipeline: dict[str, list[InjectionAlone]] = defaultdict(list)
    for a in alone:
        alone_by_pipeline[a.pipeline].append(a)

    out = [
        f"# {suite} × `{attack}` — user task × injection task 결과",
        "",
        f"- logdir: `{logdir}`",
        f"- suite: `{suite}`, attack: `{attack}`",
        f"- pipelines: {', '.join(f'`{p}`' for p in sorted(by_pipeline))}",
        "",
        "셀: **✓** 성공, **✗** 실패, **!** 실행 오류, 빈칸 = 로그 없음. "
        "공격 성공은 `security=True`(injection task 목표 달성), utility 성공은 `utility=True`(유저 태스크 완수).",
    ]
    for pipeline in sorted(by_pipeline):
        pc = by_pipeline[pipeline]
        n_ut = len({c.user_task for c in pc})
        n_it = len({c.injection_task for c in pc})
        sec = sum(c.security for c in pc)
        util = sum(c.utility for c in pc)
        both = sum(c.security and c.utility for c in pc)
        errs = sum(c.error is not None for c in pc)
        if len(by_pipeline) > 1:
            out += ["", f"## pipeline `{pipeline}`"]
        out += [
            "",
            "| 항목 | 값 |",
            "|---|---:|",
            f"| user tasks | {n_ut} |",
            f"| injection tasks | {n_it} |",
            f"| cases | {len(pc)} |",
            f"| 공격 성공 (targeted ASR) | {sec}/{len(pc)} ({_pct(sec, len(pc))}) |",
            f"| utility 성공 (under attack) | {util}/{len(pc)} ({_pct(util, len(pc))}) |",
            f"| 공격·utility 둘 다 성공 | {both}/{len(pc)} ({_pct(both, len(pc))}) |",
            f"| errors | {errs} |",
            "",
            "### 1. 공격 성공 격자 (security)",
            "",
            *render_grid(pc, "security", "ASR"),
            "",
            "### 2. utility 성공 격자 (utility under attack)",
            "",
            *render_grid(pc, "utility", "utility"),
            "",
            "### 3. 케이스 목록",
            "",
            *render_cases(pc),
        ]
        pa = alone_by_pipeline.get(pipeline)
        if pa:
            out += [
                "",
                "### 4. injection task 단독 실행 utility (injection task를 유저 태스크로 직접 주었을 때)",
                "",
                *render_alone(pa),
            ]
    return "\n".join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


@click.command()
@click.option("--logdir", type=Path, default=Path("./runs/agentdojo"), show_default=True)
@click.option("--suite", "-s", required=True, help="표를 만들 suite (예: banking).")
@click.option("--attack", "-a", required=True, help="표를 만들 attack type (예: important_instructions).")
@click.option("--pipeline", "-p", default=None, help="logdir에 pipeline(모델/방어)이 여러 개일 때 하나만 고른다. 생략 시 전부 (pipeline별 섹션).")
@click.option("--out", type=Path, default=None, help="Markdown 출력 경로. 생략 시 stdout.")
def main(logdir: Path, suite: str, attack: str, pipeline: str | None, out: Path | None) -> None:
    if not logdir.is_dir():
        raise click.ClickException(f"logdir not found: {logdir}")
    cases, alone, seen = scan(logdir, suite, attack)
    if pipeline:
        cases = [c for c in cases if c.pipeline == pipeline]
        alone = [a for a in alone if a.pipeline == pipeline]
    if not cases:
        found = ", ".join(f"{s}/{a}" for s, a in sorted(seen)) or "(none)"
        hint = f" for pipeline '{pipeline}'" if pipeline else ""
        raise click.ClickException(
            f"No attack logs for suite '{suite}' attack '{attack}'{hint} under {logdir}. Found suite/attack: {found}"
        )
    md = render_markdown(suite, attack, logdir, cases, alone)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(md + "\n")
        print(f"wrote {out}")
    else:
        print(md)


if __name__ == "__main__":
    main()
