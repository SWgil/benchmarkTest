#!/usr/bin/env bash
# AutoDojo 2단계: 우리 Ollama 모델을 타깃으로 인젝션을 직접 최적화한다.
# 공격자(analyzer + rewriter) LLM도 Ollama 모델을 쓴다 (OPTIMIZER_MODEL, 기본 = 타깃과 같은 모델).
#   SUITES="banking" ITERATIONS=8 N_VARIANTS=5 DEFENSE=spotlighting scripts/run_autodojo_optimize.sh
#   OPT_EXTRA="--max-injection-tasks 2 --parallel-eval --eval-concurrency 4" 로 optimize_variants.py 인자 추가
# 결과: runs/autodojo/variants/<suite>/<model>/<defense>/injections.json 이 생기고, 이어서 --attack autodojo 로 벤치마크한다.
BENCH=autodojo source "$(dirname "$0")/common.sh"
OPTIMIZER_MODEL="${OPTIMIZER_MODEL:-$OLLAMA_MODEL}"
ITERATIONS="${ITERATIONS:-8}"
N_VARIANTS="${N_VARIANTS:-5}"
DEFENSE="${DEFENSE:-}"
OPT_EXTRA="${OPT_EXTRA:-}"
OUT_DIR="${OUT_DIR:-$LOGDIR/variants}"

# 타깃 (vllm_parsed 경로) 과 최적화 LLM (provider ollama) 모두 Ollama 서버로
export LOCAL_LLM_BASE_URL="$OLLAMA_BASE_URL"
export LOCAL_LLM_MODEL_ID="$OLLAMA_MODEL"
export LOCAL_LLM_API_KEY="${OLLAMA_API_KEY:-ollama}"
export LOCAL_LLM_REASONING_EFFORT="${LOCAL_LLM_REASONING_EFFORT:-none}"     # 타깃 thinking off
export OLLAMA_REASONING_EFFORT="${OLLAMA_REASONING_EFFORT:-}"               # 최적화 LLM은 기본값(모델 기본 thinking)
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
mkdir -p "$OUT_DIR"
export AUTODOJO_OUTPUT_DIR="$(cd "$OUT_DIR" && pwd)"      # optimize_variants.py 는 절대 경로를 기대
export AUTODOJO_COST_TRACKING="${AUTODOJO_COST_TRACKING:-0}"
export AGENTDOJO_RUN_INJECTION_UTILITY="${AGENTDOJO_RUN_INJECTION_UTILITY:-0}"

AD=third_party/AutoDojo/agentdojo
defense_opt=""; defense_cell="no_defense"
if [[ -n "$DEFENSE" ]]; then defense_opt="--defense $DEFENSE --run-defense"; defense_cell="$DEFENSE"; fi

for suite in $SUITES; do
  echo "### optimize suite=$suite target=$OLLAMA_MODEL optimizer=$OPTIMIZER_MODEL defense=${DEFENSE:-none}"
  PYTHONPATH="$AD/src:$AD/variant_generation" python "$AD/variant_generation/optimize_variants.py" \
    --suite "$suite" --n-variants "$N_VARIANTS" --iterations "$ITERATIONS" \
    --eval-asr --target-model vllm_parsed --target-model-id "$OLLAMA_MODEL" \
    --model "$OPTIMIZER_MODEL" --provider ollama \
    --analyzer-prompt "analyzer_$suite" --injection-prompt "injection_task_iterative_$suite" \
    $defense_opt $OPT_EXTRA
  cache="$AUTODOJO_OUTPUT_DIR/$suite/$OLLAMA_MODEL/$defense_cell/injections.json"
  if [[ -f "$cache" ]]; then
    echo "### benchmark suite=$suite with $cache"
    darg=""; [[ -n "$DEFENSE" ]] && darg="--defense $DEFENSE"
    $RUN -s "$suite" --attack autodojo --autodojo-cache "$cache" --autodojo-variant 0 $darg $EXTRA_ARGS "$@"
  else
    echo "!! expected cache not found: $cache"
  fi
done
