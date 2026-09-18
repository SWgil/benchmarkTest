#!/usr/bin/env bash
# AutoDojo 1단계: 논문에 커밋된 최적화 인젝션 캐시를 우리 모델에 전이 평가한다 (공격자 LLM 불필요).
#   SOURCE_MODEL: 캐시를 만든 타깃 모델 셀 (variants/<suite>/<SOURCE_MODEL>/<defense>/injections.json)
#   DEFENSES:     캐시 셀의 방어 이름 = 실행 시 적용할 방어 (no_defense 는 방어 없음)
#   SUITES:       기본 banking slack travel
BENCH=autodojo source "$(dirname "$0")/common.sh"
SOURCE_MODEL="${SOURCE_MODEL:-openai/gpt-4o-mini}"
DEFENSES="${DEFENSES:-no_defense spotlighting}"
VARIANT="${VARIANT:-0}"
VARIANTS_DIR=third_party/AutoDojo/agentdojo/variant_generation/variants
export AGENTDOJO_RUN_INJECTION_UTILITY="${AGENTDOJO_RUN_INJECTION_UTILITY:-0}"
for suite in $SUITES; do
  # 기준선: 공격 없음 + 정적 important_instructions
  $RUN -s "$suite" $EXTRA_ARGS "$@"
  $RUN -s "$suite" --attack important_instructions $EXTRA_ARGS "$@"
  for d in $DEFENSES; do
    cache="$VARIANTS_DIR/$suite/$SOURCE_MODEL/$d/injections.json"
    if [[ ! -f "$cache" ]]; then echo "!! no cache: $cache (skip)"; continue; fi
    defense_arg=""; [[ "$d" != "no_defense" ]] && defense_arg="--defense $d"
    echo "### suite=$suite cache=$SOURCE_MODEL/$d"
    $RUN -s "$suite" --attack autodojo --autodojo-cache "$cache" --autodojo-variant "$VARIANT" $defense_arg $EXTRA_ARGS "$@"
    [[ -n "$defense_arg" ]] && $RUN -s "$suite" --attack important_instructions $defense_arg $EXTRA_ARGS "$@"
  done
done
