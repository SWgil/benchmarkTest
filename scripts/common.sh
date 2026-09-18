# 모든 실행 스크립트가 source 하는 공통 설정.
# 사용법: BENCH=agentdyn CONFIG=configs/qwen3.8-27b.env scripts/run_smoke.sh
#   BENCH: agentdojo (기본) | agentdyn | autodojo  → 사용할 venv, 기본 로그 디렉터리, suite 목록이 달라짐
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BENCH="${BENCH:-agentdojo}"
case "$BENCH" in agentdojo|agentdyn|autodojo) ;; *) echo "BENCH must be agentdojo|agentdyn|autodojo (got '$BENCH')"; exit 1;; esac

CONFIG="${CONFIG:-configs/qwen3.8-27b.env}"
if [[ -f "$CONFIG" ]]; then
  set -a; source "$CONFIG"; set +a
fi
if [[ -f .env ]]; then
  set -a; source .env; set +a   # .env가 configs/ 값을 덮어씀
fi
: "${OLLAMA_BASE_URL:?OLLAMA_BASE_URL is not set (see .env.example)}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL is not set (see .env.example)}"

# venv 선택: VENV 명시 > .venv-$BENCH > (agentdojo일 때) .venv
VENV="${VENV:-.venv-$BENCH}"
if [[ ! -d "$VENV" && "$BENCH" == "agentdojo" && -d .venv ]]; then VENV=.venv; fi
if [[ -d "$VENV" ]]; then
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
else
  echo "[common] venv '$VENV' not found. Run scripts/setup_${BENCH}.sh first (agentdojo: README 설치 절차)." >&2
  exit 1
fi

LOGDIR="${LOGDIR:-runs/$BENCH}"
MAX_WORKERS="${MAX_WORKERS:-1}"
EXTRA_ARGS="${EXTRA_ARGS:-}"   # 예: EXTRA_ARGS="--reasoning-effort '' --no-no-think-tag" (thinking on 실험)
RUN="agentdojo-ollama --logdir $LOGDIR"
case "$BENCH" in
  agentdojo) DEFAULT_SUITES="workspace slack travel banking" ;;
  agentdyn)  DEFAULT_SUITES="shopping github dailylife" ;;      # AgentDyn 고유 3개 (원본 4개도 포함되어 있음)
  autodojo)  DEFAULT_SUITES="banking slack travel" ;;           # 논문 범위 (github/shopping/dailylife도 가능)
esac
SUITES="${SUITES:-$DEFAULT_SUITES}"
SUITE_ARGS=""; for s in $SUITES; do SUITE_ARGS="$SUITE_ARGS -s $s"; done
echo "[common] bench=$BENCH venv=$VENV model=$OLLAMA_MODEL base_url=$OLLAMA_BASE_URL logdir=$LOGDIR workers=$MAX_WORKERS suites=[$SUITES]"
