#!/usr/bin/env bash
# AgentVigil 재구현: 우리 Ollama 모델(방어 없음)을 타깃으로 인젝션 템플릿을 MCTS 로 탐색하고,
# 만든 캐시로 --attack agentvigil 벤치마크를 돌린다. 공격자(변이) LLM 도 Ollama.
#   SUITES="banking" ITERATIONS=10 MUT=3 scripts/run_agentvigil.sh
#   SAMPLE_FRAC=0.25  케이스 샘플 비율 (논문 1/4). OPT_EXTRA 로 최적화기 인자 추가.
#   HELPER_MODEL / HELPER_REASONING_EFFORT 로 공격자 LLM 변경 (기본 = 타깃과 같은 모델).
# 결과: runs/<bench>/variants/<suite>/agentvigil.json 생성 후 벤치마크.
source "$(dirname "$0")/common.sh"
ITERATIONS="${ITERATIONS:-10}"
MUT="${MUT:-3}"
SAMPLE_FRAC="${SAMPLE_FRAC:-0.25}"
OPT_EXTRA="${OPT_EXTRA:-}"
OUT_DIR="${OUT_DIR:-$LOGDIR/variants}"
mkdir -p "$OUT_DIR"

for suite in $SUITES; do
  cache="$OUT_DIR/$suite/agentvigil.json"
  echo "### AgentVigil optimize suite=$suite target=$OLLAMA_MODEL helper=${HELPER_MODEL:-$OLLAMA_MODEL}"
  agentdojo-agentvigil -s "$suite" \
    --iterations "$ITERATIONS" --mutations-per-iter "$MUT" --sample-frac "$SAMPLE_FRAC" \
    --out "$cache" $OPT_EXTRA
  if [[ -f "$cache" ]]; then
    echo "### benchmark suite=$suite --attack agentvigil"
    $RUN -s "$suite" --attack agentvigil --adaptive-cache "$cache" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
  else
    echo "!! expected cache not found: $cache"
  fi
done
