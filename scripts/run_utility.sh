#!/usr/bin/env bash
# Phase 3 E1: 공격 없이 전체 suite 유틸리티 (97 user tasks).
source "$(dirname "$0")/common.sh"
$RUN --max-workers "$MAX_WORKERS" $EXTRA_ARGS "$@"
