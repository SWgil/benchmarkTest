#!/usr/bin/env bash
# 공격 하나·suite 하나를 골라 모든 user task × injection task 의 공격 성공 / utility 성공 표를
# results/<bench>_<model>_<suite>_<attack>_tasks_<date>.md 로 만든다.
#   사용법: SUITE=banking ATTACK=important_instructions scripts/task_table.sh
#   PIPELINE=<model[-defense]> 로 logdir 안의 pipeline 하나만 고를 수 있다 (기본: 전부).
source "$(dirname "$0")/common.sh"
SUITE="${SUITE:-banking}"
ATTACK="${ATTACK:-important_instructions}"
PIPELINE_ARGS=(); if [[ -n "${PIPELINE:-}" ]]; then PIPELINE_ARGS=(-p "$PIPELINE"); fi
STEM="results/${BENCH}_$(echo "$OLLAMA_MODEL" | tr ':/' '--')_${SUITE}_${ATTACK}_tasks_$(date +%Y%m%d)"
agentdojo-task-table --logdir "$LOGDIR" -s "$SUITE" -a "$ATTACK" "${PIPELINE_ARGS[@]}" --out "$STEM.md" "$@"
cat "$STEM.md"
