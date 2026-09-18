#!/usr/bin/env bash
# (범위 밖, 선택) 방어 기법별 실행. 이 저장소의 목적은 방어 없는 LLM 자체 저항성 측정이므로 기본 워크플로에 포함되지 않는다.
# DEFENSES 환경변수로 목록 지정 가능.
#   transformers_pi_detector 는 `pip install -e ".[transformers]"` 필요.
source "$(dirname "$0")/common.sh"
ATTACK="${ATTACK:-important_instructions}"
DEFENSES="${DEFENSES:-tool_filter repeat_user_prompt spotlighting_with_delimiting}"
for d in $DEFENSES; do
  echo "### defense=$d (no attack)"
  $RUN $SUITE_ARGS --defense "$d" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
  echo "### defense=$d attack=$ATTACK"
  $RUN $SUITE_ARGS --defense "$d" --attack "$ATTACK" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
done
