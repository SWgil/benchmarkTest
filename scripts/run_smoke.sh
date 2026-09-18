#!/usr/bin/env bash
# Phase 2: 스모크 테스트. workspace suite 태스크 2개(공격 없음) + 1개(공격 있음).
source "$(dirname "$0")/common.sh"
$RUN -s workspace -ut user_task_0 -ut user_task_1 $EXTRA_ARGS
$RUN -s workspace -ut user_task_0 -it injection_task_0 --attack important_instructions $EXTRA_ARGS
echo "로그: $LOGDIR/$OLLAMA_MODEL/workspace/"
