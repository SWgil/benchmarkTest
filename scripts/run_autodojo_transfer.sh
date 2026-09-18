#!/usr/bin/env bash
# AutoDojo 1단계: 논문에 커밋된 최적화 인젝션 캐시를 우리 모델에 전이 평가한다 (공격자 LLM 불필요).
#   SOURCE_MODEL: 캐시를 만든 타깃 모델 셀 (variants/<suite>/<SOURCE_MODEL>/<defense>/injections.json)
#   DEFENSES:     캐시 셀의 방어 이름 = 실행 시 적용할 방어. 기본 no_defense (이 저장소의 목적은 방어 없는 LLM 자체 저항성).
#                 방어까지 보고 싶을 때만 DEFENSES="no_defense spotlighting" 처럼 지정.
#   SUITES:       기본 banking slack travel (캐시가 있는 suite. 태스크 자체는 원본 AgentDojo와 동일)
#   RUN_BASELINES=1        방어 없는 기준선(공격 없음 + 정적 important_instructions)도 이 포크에서 다시 실행.
#                          기본 0: 같은 태스크를 BENCH=agentdojo E1/E2 가 이미 돌리므로 그 결과를 기준선으로 쓴다.
#   RUN_STATIC_DEFENSE=1   방어를 건 정적 important_instructions 기준선 (기본 0; DEFENSES 에 방어를 넣었을 때만 의미 있음)
BENCH=autodojo source "$(dirname "$0")/common.sh"
SOURCE_MODEL="${SOURCE_MODEL:-openai/gpt-4o-mini}"
DEFENSES="${DEFENSES:-no_defense}"
VARIANT="${VARIANT:-0}"
RUN_BASELINES="${RUN_BASELINES:-0}"
RUN_STATIC_DEFENSE="${RUN_STATIC_DEFENSE:-0}"
VARIANTS_DIR=third_party/AutoDojo/agentdojo/variant_generation/variants
export AGENTDOJO_RUN_INJECTION_UTILITY="${AGENTDOJO_RUN_INJECTION_UTILITY:-0}"
for suite in $SUITES; do
  if [[ "$RUN_BASELINES" == "1" ]]; then
    $RUN -s "$suite" $EXTRA_ARGS "$@"
    $RUN -s "$suite" --attack important_instructions $EXTRA_ARGS "$@"
  else
    echo "### suite=$suite: 방어 없는 기준선은 건너뜀 (runs/agentdojo 의 E1/E2 사용, RUN_BASELINES=1 로 재실행 가능)"
  fi
  for d in $DEFENSES; do
    cache="$VARIANTS_DIR/$suite/$SOURCE_MODEL/$d/injections.json"
    if [[ ! -f "$cache" ]]; then echo "!! no cache: $cache (skip)"; continue; fi
    defense_arg=""; [[ "$d" != "no_defense" ]] && defense_arg="--defense $d"
    echo "### suite=$suite cache=$SOURCE_MODEL/$d"
    $RUN -s "$suite" --attack autodojo --autodojo-cache "$cache" --autodojo-variant "$VARIANT" $defense_arg $EXTRA_ARGS "$@"
    if [[ -n "$defense_arg" && "$RUN_STATIC_DEFENSE" == "1" ]]; then
      $RUN -s "$suite" --attack important_instructions $defense_arg $EXTRA_ARGS "$@"
    fi
  done
done
