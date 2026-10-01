#!/usr/bin/env bash
# IterInject 재구현: (user_task, injection_task) 케이스마다 피드백 기반으로 인젝션을 반복 최적화하고,
# 만든 캐시로 --attack iterinject 벤치마크를 돌린다. 최적화 LLM 도 Ollama.
#   SUITES="banking" ITERATIONS=7 PATIENCE=3 scripts/run_iterinject.sh
#   SAMPLE_FRAC=0.25  케이스 샘플 비율. OPT_EXTRA 로 최적화기 인자 추가 (예: --max-injection-tasks 2).
#   HELPER_MODEL / HELPER_REASONING_EFFORT 로 최적화 LLM 변경 (기본 = 타깃과 같은 모델).
# 비용 주의: 케이스당 최대 ITERATIONS 회 타깃 호출. 케이스가 많으면 --max-* 또는 SAMPLE_FRAC 로 줄여라.
# 결과: runs/<bench>/variants/<suite>/iterinject.json 생성 후 벤치마크.
source "$(dirname "$0")/common.sh"
ITERATIONS="${ITERATIONS:-7}"
PATIENCE="${PATIENCE:-3}"
SAMPLE_FRAC="${SAMPLE_FRAC:-0.25}"
OPT_EXTRA="${OPT_EXTRA:-}"
OUT_DIR="${OUT_DIR:-$LOGDIR/variants}"
mkdir -p "$OUT_DIR"

for suite in $SUITES; do
  cache="$OUT_DIR/$suite/iterinject.json"
  echo "### IterInject optimize suite=$suite target=$OLLAMA_MODEL helper=${HELPER_MODEL:-$OLLAMA_MODEL}"
  agentdojo-iterinject -s "$suite" \
    --iterations "$ITERATIONS" --patience "$PATIENCE" --sample-frac "$SAMPLE_FRAC" \
    --out "$cache" $OPT_EXTRA
  if [[ -f "$cache" ]]; then
    echo "### benchmark suite=$suite --attack iterinject"
    $RUN -s "$suite" --attack iterinject --adaptive-cache "$cache" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
  else
    echo "!! expected cache not found: $cache"
  fi
done
