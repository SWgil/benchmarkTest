#!/usr/bin/env bash
# Phase 4: runs/ 집계 → results/<model>_<date>.md / .csv
source "$(dirname "$0")/common.sh"
STEM="results/$(echo "$OLLAMA_MODEL" | tr ':/' '--')_$(date +%Y%m%d)"
agentdojo-summarize --logdir "$LOGDIR" --out "$STEM.md" --csv "$STEM.csv"
{
  echo; echo "## 실행 환경"
  echo "- model: $OLLAMA_MODEL @ $OLLAMA_BASE_URL"
  echo "- ollama version: $(curl -sf "${OLLAMA_BASE_URL%/v1}/api/version" 2>/dev/null || echo unknown)"
  echo "- model digest: $(curl -sf "${OLLAMA_BASE_URL%/v1}/api/tags" 2>/dev/null | python3 -c "import json,sys; print(next((m['digest'] for m in json.load(sys.stdin)['models'] if m['name']=='$OLLAMA_MODEL'),'unknown'))" 2>/dev/null || echo unknown)"
  echo "- agentdojo: $(python -c 'import importlib.metadata as m; print(m.version("agentdojo"))')"
  echo "- extra args: ${EXTRA_ARGS:-(none)}"
} >> "$STEM.md"
cat "$STEM.md"
