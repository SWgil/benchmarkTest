#!/usr/bin/env bash
# 공격 변형 간 ASR 차이 분석: runs/<bench>/ 의 두(또는 여러) 공격 로그를 케이스 단위로 비교해
# results/<bench>_<model>_<suite>_<attacks>_<date>.md 를 만든다.
#   사용법: SUITE=banking ATTACKS="direct ignore_previous" scripts/compare_attacks.sh
#   ATTACKS 를 비우면 로그에 있는 공격 전부를 비교한다 (차이 격자는 공격이 정확히 2개일 때만).
source "$(dirname "$0")/common.sh"
SUITE="${SUITE:-banking}"
ATTACKS="${ATTACKS:-direct ignore_previous}"
ATTACK_ARGS=""; for a in $ATTACKS; do ATTACK_ARGS="$ATTACK_ARGS -a $a"; done
STEM="results/${BENCH}_$(echo "$OLLAMA_MODEL" | tr ':/' '--')_${SUITE}_$(echo "$ATTACKS" | tr ' ' '-')_$(date +%Y%m%d)"
# shellcheck disable=SC2086
agentdojo-compare --logdir "$LOGDIR" -s "$SUITE" $ATTACK_ARGS \
  --benchmark-version "${BENCHMARK_VERSION:-v1.2.2}" \
  --out "$STEM.md" --json "$STEM.json" "$@"
cat "$STEM.md"
