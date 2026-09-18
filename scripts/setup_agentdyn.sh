#!/usr/bin/env bash
# AgentDyn (SaFo-Lab/AgentDyn) 포크를 third_party/ 에 받고 전용 venv(.venv-agentdyn)에 설치한다.
# 포크는 패키지 이름이 'agentdojo' 그대로라 원본과 같은 venv에 공존할 수 없다.
# runs/ (논문 로그 700MB+)는 sparse checkout으로 제외한다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
AGENTDYN_COMMIT="${AGENTDYN_COMMIT:-5353cf7615b135cace8d07c8f12dac53a16b6db3}"
DIR=third_party/AgentDyn
VENV="${VENV:-.venv-agentdyn}"
PY="${PYTHON:-python3}"

if [[ ! -d "$DIR/.git" ]]; then
  git clone --filter=blob:none --sparse https://github.com/SaFo-Lab/AgentDyn.git "$DIR"
  git -C "$DIR" sparse-checkout set src
fi
git -C "$DIR" fetch -q origin "$AGENTDYN_COMMIT" 2>/dev/null || git -C "$DIR" fetch -q origin
git -C "$DIR" checkout -q "$AGENTDYN_COMMIT"
echo "[setup] AgentDyn @ $(git -C "$DIR" rev-parse --short HEAD)"

[[ -d "$VENV" ]] || $PY -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -e "$DIR"            # 포크가 'agentdojo' 로 설치됨
"$VENV/bin/pip" install -q --no-deps -e .       # 우리 러너 (PyPI agentdojo 로 덮어쓰지 않도록 --no-deps)
"$VENV/bin/python" -c "from agentdojo_ollama.compat import detect_bench; print('[setup] detected bench:', detect_bench())"
echo "[setup] done. 사용: BENCH=agentdyn scripts/run_smoke.sh"
