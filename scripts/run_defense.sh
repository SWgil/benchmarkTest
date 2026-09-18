#!/usr/bin/env bash
# Phase 3 E4: 방어 기법별 실행. DEFENSES 환경변수로 목록 지정 가능.
#   transformers_pi_detector 는 `pip install -e ".[transformers]"` 필요.
source "$(dirname "$0")/common.sh"
ATTACK="${ATTACK:-important_instructions}"
DEFENSES="${DEFENSES:-tool_filter repeat_user_prompt spotlighting_with_delimiting}"
for d in $DEFENSES; do
  echo "### defense=$d (no attack)"
  $RUN --defense "$d" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
  echo "### defense=$d attack=$ATTACK"
  $RUN --defense "$d" --attack "$ATTACK" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
done
