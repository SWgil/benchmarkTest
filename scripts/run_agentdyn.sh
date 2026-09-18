#!/usr/bin/env bash
# AgentDyn 3개 suite(shopping, github, dailylife)에 대해 E1(공격 없음) + E2(important_instructions).
#   SUITES="shopping" ATTACK=tool_knowledge scripts/run_agentdyn.sh
BENCH=agentdyn source "$(dirname "$0")/common.sh"
ATTACK="${ATTACK:-important_instructions}"
$RUN $SUITE_ARGS --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
$RUN $SUITE_ARGS --attack "$ATTACK" --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
