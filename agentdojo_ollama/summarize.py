"""runs/ 아래의 AgentDojo 로그를 집계해 Utility / Targeted ASR / Utility-under-attack 표를 만든다.

로그 구조 (agentdojo TraceLogger):
    <logdir>/<pipeline>/<suite>/<user_task>/<attack|none>/<injection_task|none>.json
각 JSON에는 utility(bool), security(bool), duration(float), error(str|None)가 있다.
security=True는 인젝션 태스크의 목표가 달성되었다는 뜻이므로, 평균이 곧 Targeted ASR이다.
"""

from __future__ import annotations

import csv
import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import click


@dataclass
class Agg:
    n: int = 0
    utility: int = 0
    security: int = 0
    errors: int = 0
    duration: float = 0.0
    inj_n: int = 0
    inj_utility: int = 0

    def add_injection_task(self, rec: dict) -> None:
        """인젝션 태스크를 유저 태스크로 실행한 결과 (공격 실행 시 함께 생성됨)."""
        self.inj_n += 1
        self.inj_utility += bool(rec.get("utility"))

    def add(self, rec: dict) -> None:
        self.n += 1
        self.utility += bool(rec.get("utility"))
        self.security += bool(rec.get("security"))
        self.errors += rec.get("error") is not None
        self.duration += rec.get("duration") or 0.0

    def pct(self, k: int) -> str:
        return f"{k / self.n * 100:.1f}%" if self.n else "-"


def scan(logdir: Path) -> dict[tuple[str, str, str], Agg]:
    """(pipeline, attack, suite) -> Agg. attack 'none'은 공격 없는 유틸리티 실행."""
    table: dict[tuple[str, str, str], Agg] = defaultdict(Agg)
    for path in sorted(logdir.glob("*/*/*/*/*.json")):
        pipeline, suite, user_task, attack = path.relative_to(logdir).parts[:4]
        try:
            rec = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"skip (invalid json): {path}", file=sys.stderr)
            continue
        if user_task.startswith("injection_task"):
            table[(pipeline, attack, suite)].add_injection_task(rec)
        else:
            table[(pipeline, attack, suite)].add(rec)
    return table


def render_markdown(table: dict[tuple[str, str, str], Agg]) -> str:
    lines = [
        "| pipeline | attack | suite | cases | utility | targeted ASR | inj. tasks solvable | errors | avg sec/case |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    combined: dict[tuple[str, str], Agg] = defaultdict(Agg)
    for (pipeline, attack, suite), a in sorted(table.items()):
        c = combined[(pipeline, attack)]
        c.n += a.n
        c.utility += a.utility
        c.security += a.security
        c.errors += a.errors
        c.duration += a.duration
        c.inj_n += a.inj_n
        c.inj_utility += a.inj_utility
        lines.append(_row(pipeline, attack, suite, a))
    for (pipeline, attack), a in sorted(combined.items()):
        lines.append(_row(pipeline, attack, "**all**", a))
    return "\n".join(lines)


def _row(pipeline: str, attack: str, suite: str, a: Agg) -> str:
    asr = a.pct(a.security) if attack != "none" else "n/a"
    avg = f"{a.duration / a.n:.1f}" if a.n else "-"
    inj = f"{a.inj_utility}/{a.inj_n}" if a.inj_n else "-"
    return f"| {pipeline} | {attack} | {suite} | {a.n} | {a.pct(a.utility)} | {asr} | {inj} | {a.errors} | {avg} |"


def write_csv(table: dict[tuple[str, str, str], Agg], path: Path) -> None:
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["pipeline", "attack", "suite", "cases", "utility_pct", "asr_pct", "inj_tasks_solved", "inj_tasks_total", "errors", "total_duration_s"])
        for (pipeline, attack, suite), a in sorted(table.items()):
            w.writerow(
                [
                    pipeline,
                    attack,
                    suite,
                    a.n,
                    round(a.utility / a.n * 100, 2) if a.n else "",
                    round(a.security / a.n * 100, 2) if a.n and attack != "none" else "",
                    a.inj_utility,
                    a.inj_n,
                    a.errors,
                    round(a.duration, 1),
                ]
            )


@click.command()
@click.option("--logdir", type=Path, default=Path("./runs"), show_default=True)
@click.option("--out", type=Path, default=None, help="Markdown 출력 경로 (예: results/qwen3.8-27b.md). 생략 시 stdout.")
@click.option("--csv", "csv_path", type=Path, default=None, help="CSV 출력 경로.")
def main(logdir: Path, out: Path | None, csv_path: Path | None) -> None:
    table = scan(logdir)
    if not table:
        raise click.ClickException(f"No result files found under {logdir}")
    md = render_markdown(table)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(md + "\n")
        print(f"wrote {out}")
    else:
        print(md)
    if csv_path:
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        write_csv(table, csv_path)
        print(f"wrote {csv_path}")


if __name__ == "__main__":
    main()
