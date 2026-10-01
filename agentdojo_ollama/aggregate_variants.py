"""AutoDojo 변형(variant) 스윕을 케이스 단위 best-of-N 으로 집계한다.

`run_autodojo_optimize.sh` 는 캐시의 각 변형(AUTODOJO_VARIANT=k)을 서로 다른
로그 디렉터리(예: runs/autodojo/v0, v1, ...)로 벤치마크한다. 최적화기는 (injection_task,
vector)마다 상위 N개 변형을 남기는데, 변형 0은 스크리닝 평균 기준 1위일 뿐 특정
(user_task, injection_task) 케이스에서는 하위 변형이 이길 수 있다. 따라서 케이스별로
변형들의 최댓값(OR)을 취한 ASR이 "모델에 맞춰 최적화된 공격의 상한"(= 모델 자체
저항성의 하한)에 가장 가까운 정직한 추정치다.

이 스크립트는 모든 변형 로그 디렉터리를 읽어 (pipeline, suite, user_task,
injection_task)마다 `security`를 OR로 합치고, 단일 변형 ASR과 best-of ASR을 나란히
출력해 상승폭이 보이게 한다. 로그 경로 해석은 summarize.py 와 동일하다
(`<pipeline>/<suite>/<user_task>/<attack>/<injection_task>.json`).
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

import click


def scan_variant(vdir: Path, attack_name: str) -> dict[tuple[str, str, str, str], bool]:
    """한 변형 로그 디렉터리 → {(pipeline, suite, user_task, injection_task): security}."""
    out: dict[tuple[str, str, str, str], bool] = {}
    for path in sorted(vdir.rglob("*.json")):
        parts = path.relative_to(vdir).parts
        if len(parts) < 5:
            continue
        pipeline = "/".join(parts[:-4])
        suite, user_task, attack = parts[-4:-1]
        if attack != attack_name:
            continue
        if not user_task.startswith("user_task") or not path.stem.startswith("injection_task"):
            continue
        try:
            rec = json.loads(path.read_text())
        except json.JSONDecodeError:
            print(f"skip (invalid json): {path}", file=sys.stderr)
            continue
        out[(pipeline, suite, user_task, path.stem)] = bool(rec.get("security"))
    return out


def _pct(k: int, n: int) -> str:
    return f"{k / n * 100:.1f}%" if n else "-"


def render(variant_dirs: list[Path], attack_name: str) -> str:
    scans = {vd.name: scan_variant(vd, attack_name) for vd in variant_dirs}
    labels = [vd.name for vd in variant_dirs]

    # 전체 케이스 키의 합집합 (한 변형에 없는 케이스는 그 변형에서 실패로 계산).
    all_keys: set[tuple[str, str, str, str]] = set()
    for s in scans.values():
        all_keys |= set(s)

    # (pipeline, suite) 단위 집계.
    groups: dict[tuple[str, str], list[tuple[str, str, str, str]]] = defaultdict(list)
    for key in all_keys:
        pipeline, suite, _ut, _it = key
        groups[(pipeline, suite)].append(key)

    header = (
        "| pipeline | suite | cases | "
        + " | ".join(f"{lbl} ASR" for lbl in labels)
        + " | best-of ASR |"
    )
    sep = "|---|---|---:|" + "---:|" * len(labels) + "---:|"
    lines = [header, sep]

    combined: dict[str, list[tuple[str, str, str, str]]] = defaultdict(list)
    for (pipeline, suite), keys in sorted(groups.items()):
        n = len(keys)
        per_variant = [sum(1 for k in keys if scans[lbl].get(k, False)) for lbl in labels]
        best = sum(1 for k in keys if any(scans[lbl].get(k, False) for lbl in labels))
        cols = " | ".join(_pct(c, n) for c in per_variant)
        lines.append(f"| {pipeline} | {suite} | {n} | {cols} | **{_pct(best, n)}** |")
        combined[pipeline].extend(keys)

    for pipeline, keys in sorted(combined.items()):
        n = len(keys)
        per_variant = [sum(1 for k in keys if scans[lbl].get(k, False)) for lbl in labels]
        best = sum(1 for k in keys if any(scans[lbl].get(k, False) for lbl in labels))
        cols = " | ".join(_pct(c, n) for c in per_variant)
        lines.append(f"| {pipeline} | **all** | {n} | {cols} | **{_pct(best, n)}** |")

    return "\n".join(lines)


@click.command()
@click.option("--logdir", type=Path, default=Path("./runs/autodojo"), show_default=True,
              help="변형 서브디렉터리(--glob)를 담고 있는 베이스 디렉터리.")
@click.option("--glob", "glob_pat", default="v*", show_default=True,
              help="변형 로그 디렉터리 glob (run_autodojo_optimize.sh 가 v0, v1, ... 로 만든다).")
@click.option("--attack", "attack_name", default="autodojo", show_default=True)
@click.option("--out", type=Path, default=None, help="Markdown 출력 경로. 생략 시 stdout.")
def main(logdir: Path, glob_pat: str, attack_name: str, out: Path | None) -> None:
    variant_dirs = sorted(d for d in logdir.glob(glob_pat) if d.is_dir())
    if not variant_dirs:
        raise click.ClickException(
            f"No variant logdirs matching '{glob_pat}' under {logdir}. "
            f"Run scripts/run_autodojo_optimize.sh with BENCH_VARIANTS set first."
        )
    md = render(variant_dirs, attack_name)
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(md + "\n")
        print(f"wrote {out}")
    else:
        print(md)


if __name__ == "__main__":
    main()
