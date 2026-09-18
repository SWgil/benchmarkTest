#!/usr/bin/env bash
# Phase 3 E2/E3: 공격 실행. 기본 important_instructions (629 cases). ATTACK=tool_knowledge 등으로 변경.
source "$(dirname "$0")/common.sh"
ATTACK="${ATTACK:-important_instructions}"
$RUN $SUITE_ARGS --attack "$ATTACK" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
