# 모든 실행 스크립트가 source 하는 공통 설정.
# 사용법: CONFIG=configs/qwen3.8-27b.env scripts/run_smoke.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CONFIG="${CONFIG:-configs/qwen3.8-27b.env}"
if [[ -f "$CONFIG" ]]; then
  set -a; source "$CONFIG"; set +a
fi
if [[ -f .env ]]; then
  set -a; source .env; set +a   # .env가 configs/ 값을 덮어씀
fi
: "${OLLAMA_BASE_URL:?OLLAMA_BASE_URL is not set (see .env.example)}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL is not set (see .env.example)}"
LOGDIR="${LOGDIR:-runs}"
MAX_WORKERS="${MAX_WORKERS:-1}"
EXTRA_ARGS="${EXTRA_ARGS:-}"   # 예: EXTRA_ARGS="--reasoning-effort '' --no-no-think-tag" (thinking on 실험)
RUN="agentdojo-ollama --logdir $LOGDIR"
if ! command -v agentdojo-ollama >/dev/null 2>&1; then
  RUN="python -m agentdojo_ollama.run --logdir $LOGDIR"
fi
echo "[common] model=$OLLAMA_MODEL base_url=$OLLAMA_BASE_URL logdir=$LOGDIR workers=$MAX_WORKERS"
