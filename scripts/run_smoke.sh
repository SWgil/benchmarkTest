#!/usr/bin/env bash
# Phase 2: 스모크 테스트. 첫 suite 태스크 2개(공격 없음) + 1개(공격 있음). BENCH=agentdyn|autodojo 도 동일.
source "$(dirname "$0")/common.sh"
SMOKE_SUITE="${SMOKE_SUITE:-$(echo $SUITES | cut -d' ' -f1)}"   # 첫 suite (agentdojo: workspace, agentdyn: shopping, autodojo: banking)
$RUN -s "$SMOKE_SUITE" -ut user_task_0 -ut user_task_1 $EXTRA_ARGS
$RUN -s "$SMOKE_SUITE" -ut user_task_0 -it injection_task_0 --attack important_instructions $EXTRA_ARGS
echo "로그: $LOGDIR/"
