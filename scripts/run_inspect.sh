#!/usr/bin/env bash
# Phase 5: AgentDojo-Inspect (UK AISI 포크, inspect_evals). 같은 Ollama 서버를 재사용한다.
#   설치: pip install -e ".[inspect]"
# Inspect의 openai-api 프로바이더는 OPENAI_API_BASE_URL 로 임의의 OpenAI 호환 서버를 가리킬 수 있다.
source "$(dirname "$0")/common.sh"
export OPENAI_API_KEY="${OLLAMA_API_KEY:-ollama}"
export OPENAI_BASE_URL="$OLLAMA_BASE_URL"
WORKSPACE="${WORKSPACE:-workspace}"       # workspace | workspace_plus | slack | travel | banking
SANDBOX="${SANDBOX:-no}"                  # workspace_plus 의 sandbox 태스크는 Docker 필요
inspect eval inspect_evals/agentdojo \
  --model "openai-api/ollama/$OLLAMA_MODEL" \
  -T workspace="$WORKSPACE" -T with_sandbox_tasks="$SANDBOX" \
  --temperature 0 --log-dir "${LOGDIR}/inspect" "$@"
echo "결과 보기: inspect view --log-dir ${LOGDIR}/inspect"
