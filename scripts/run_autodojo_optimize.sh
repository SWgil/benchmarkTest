#!/usr/bin/env bash
# AutoDojo: 우리 Ollama 모델(방어 없음)을 타깃으로 인젝션을 직접 최적화하고, 만든 캐시로 벤치마크한다.
# (논문 캐시 전이 평가는 하지 않는다. 캐시는 다른 모델에 맞춰진 것이고 상당수 셀이 정적 공격과 같아 의미가 적다.)
# 공격자(analyzer + rewriter) LLM도 Ollama 모델을 쓴다 (OPTIMIZER_MODEL, 기본 = 타깃과 같은 모델).
#   SUITES="banking" ITERATIONS=16 N_VARIANTS=8 scripts/run_autodojo_optimize.sh
#   DEFENSE 는 기본 비움 = 방어 없는 타깃을 상대로 최적화 (이 저장소의 목적). 방어 실험 시에만 DEFENSE=spotlighting.
#   OPT_EXTRA="--max-injection-tasks 2 --parallel-eval --eval-concurrency 4" 로 optimize_variants.py 인자 추가
# 결과: runs/autodojo/variants/<suite>/<model>/<defense>/injections.json 이 생기고, 이어서 --attack autodojo 로 벤치마크한다.
#
# ── ASR 상한을 조이기 위한 설정 (낮은 ASR을 끌어올리는 레버) ─────────────────────────────
#  - 최적화 타깃을 벤치마크 타깃과 동일하게 맞춘다: <think> 제거 + seed 고정 +
#    시스템 메시지에 /no_think (LOCAL_LLM_SYSTEM_SUFFIX). 안 그러면 thinking-ON 타깃에
#    맞춰 최적화하고 thinking-OFF 타깃에서 측정해 ASR이 떨어진다.
#  - important_instructions 시드가 모델을 벤치마크와 같은 이름(MODEL_PROSE_NAME, 예: Qwen)으로
#    지칭하도록 AUTODOJO_PROSE_NAME 을 넘긴다.
#  - ITERATIONS/N_VARIANTS 기본값을 높였다 (8/5 → 16/8). 비용이 그만큼 늘어난다.
#  - suite별로 사용 가능한 시드 스타일을 자동 선택한다 (아래 SEED_STYLES).
#  - BENCH_VARIANTS 로 여러 변형을 각각 벤치마크해 케이스별 best-of 로 집계한다 (ASR 상한).
BENCH=autodojo source "$(dirname "$0")/common.sh"
OPTIMIZER_MODEL="${OPTIMIZER_MODEL:-$OLLAMA_MODEL}"
ITERATIONS="${ITERATIONS:-16}"
N_VARIANTS="${N_VARIANTS:-8}"
DEFENSE="${DEFENSE:-}"
OPT_EXTRA="${OPT_EXTRA:-}"
OUT_DIR="${OUT_DIR:-$LOGDIR/variants}"
# 케이스별 best-of 로 집계할 변형 인덱스들. 각 변형을 전체 suite에 대해 따로 벤치마크하므로
# 변형 수만큼 벤치마크 비용이 늘어난다 (기본 3개 = 3배). 단일 변형만 보려면 BENCH_VARIANTS=0.
BENCH_VARIANTS="${BENCH_VARIANTS:-0 1 2}"

# 타깃 (vllm_parsed 경로) 과 최적화 LLM (provider ollama) 모두 Ollama 서버로
export LOCAL_LLM_BASE_URL="$OLLAMA_BASE_URL"
export LOCAL_LLM_MODEL_ID="$OLLAMA_MODEL"
export LOCAL_LLM_API_KEY="${OLLAMA_API_KEY:-ollama}"
export LOCAL_LLM_REASONING_EFFORT="${LOCAL_LLM_REASONING_EFFORT:-none}"     # 타깃 thinking off
# 최적화 타깃을 벤치마크 러너와 동일하게: 시스템 메시지 /no_think + seed 고정.
# (패치된 get_llm 이 vllm_parsed 를 OllamaLLM 으로 라우팅해 <think> 를 제거하고 seed 를 보낸다.)
export LOCAL_LLM_SYSTEM_SUFFIX="${LOCAL_LLM_SYSTEM_SUFFIX:- /no_think}"
export LOCAL_LLM_SEED="${LOCAL_LLM_SEED:-0}"
export AUTODOJO_PROSE_NAME="${AUTODOJO_PROSE_NAME:-${MODEL_PROSE_NAME:-Qwen}}"
export OLLAMA_REASONING_EFFORT="${OLLAMA_REASONING_EFFORT:-}"               # 최적화 LLM은 기본값(모델 기본 thinking)
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}"
mkdir -p "$OUT_DIR"
export AUTODOJO_OUTPUT_DIR="$(cd "$OUT_DIR" && pwd)"      # optimize_variants.py 는 절대 경로를 기대
export AUTODOJO_COST_TRACKING="${AUTODOJO_COST_TRACKING:-0}"
export AGENTDOJO_RUN_INJECTION_UTILITY="${AGENTDOJO_RUN_INJECTION_UTILITY:-0}"

# suite별 사용 가능한 외부 시드 캐시. banking/slack/travel 에는 rlhammer+topicattack 캐시가,
# AgentDyn suite(shopping/github/dailylife)에는 procedural 캐시가 커밋되어 있다. 없는 스타일을
# 주면 optimize_variants.py 가 fail-fast 하므로 suite별로 맞춰 고른다. SEED_STYLES 로 덮어쓸 수 있다.
seed_styles_for() {
  case "$1" in
    banking|slack|travel) echo "rlhammer topicattack" ;;
    shopping|github|dailylife) echo "procedural" ;;
    *) echo "" ;;
  esac
}

AD=third_party/AutoDojo/agentdojo
defense_opt=""; defense_cell="no_defense"
if [[ -n "$DEFENSE" ]]; then defense_opt="--defense $DEFENSE --run-defense"; defense_cell="$DEFENSE"; fi

for suite in $SUITES; do
  styles="${SEED_STYLES:-$(seed_styles_for "$suite")}"
  seed_opt=""; [[ -n "$styles" ]] && seed_opt="--seed-styles $styles"
  echo "### optimize suite=$suite target=$OLLAMA_MODEL optimizer=$OPTIMIZER_MODEL defense=${DEFENSE:-none} iterations=$ITERATIONS n_variants=$N_VARIANTS seeds=[$styles]"
  PYTHONPATH="$AD/src:$AD/variant_generation" python "$AD/variant_generation/optimize_variants.py" \
    --suite "$suite" --n-variants "$N_VARIANTS" --iterations "$ITERATIONS" \
    --eval-asr --target-model vllm_parsed --target-model-id "$OLLAMA_MODEL" \
    --model "$OPTIMIZER_MODEL" --provider ollama \
    --analyzer-prompt "analyzer_$suite" --injection-prompt "injection_task_iterative_$suite" \
    $seed_opt $defense_opt $OPT_EXTRA
  cache="$AUTODOJO_OUTPUT_DIR/$suite/$OLLAMA_MODEL/$defense_cell/injections.json"
  if [[ ! -f "$cache" ]]; then
    echo "!! expected cache not found: $cache"
    continue
  fi
  darg=""; [[ -n "$DEFENSE" ]] && darg="--defense $DEFENSE"
  # 각 변형을 별도 로그 디렉터리(v<k>)로 벤치마크한다. 같은 로그 경로를 쓰면 공격 이름이
  # 'autodojo' 로 고정되어 변형끼리 충돌/스킵되기 때문. 이후 aggregate 로 best-of 집계.
  for v in $BENCH_VARIANTS; do
    vlogdir="$LOGDIR/v$v"
    echo "### benchmark suite=$suite variant=$v -> $vlogdir"
    agentdojo-ollama --logdir "$vlogdir" -s "$suite" --attack autodojo \
      --autodojo-cache "$cache" --autodojo-variant "$v" $darg $EXTRA_ARGS "$@"
  done
done

# 변형 스윕을 했으면 케이스별 best-of ASR 을 집계한다 (ASR 상한).
nvars="$(echo $BENCH_VARIANTS | wc -w)"
if [[ "$nvars" -gt 1 ]]; then
  stem="results/autodojo_$(echo "$OLLAMA_MODEL" | tr ':/' '--')_bestof_$(date +%Y%m%d)"
  echo "### aggregate best-of-$nvars variants -> $stem.md"
  agentdojo-autodojo-aggregate --logdir "$LOGDIR" --glob 'v*' --out "$stem.md" || true
  [[ -f "$stem.md" ]] && cat "$stem.md"
fi
