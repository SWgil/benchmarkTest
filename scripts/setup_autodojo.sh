#!/usr/bin/env bash
# AutoDojo (xhOwenMa/AutoDojo) 를 third_party/ 에 받고, Ollama 패치를 적용한 뒤 전용 venv(.venv-autodojo)에 설치한다.
# 패치 내용 (patches/autodojo-ollama.patch):
#   - 타깃 'vllm_parsed': LOCAL_LLM_BASE_URL / LOCAL_LLM_MODEL_ID / LOCAL_LLM_REASONING_EFFORT 로 원격 Ollama 지정
#   - qwen 모델에도 reasoning_effort 전송 (OpenRouter가 아닐 때)
#   - 최적화(analyzer/rewriter) LLM 프로바이더 'ollama' 추가 (OLLAMA_BASE_URL, OLLAMA_REASONING_EFFORT)
#   - DRIFT 방어 모델도 같은 환경변수로 원격 지정 가능
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
AUTODOJO_COMMIT="${AUTODOJO_COMMIT:-abbcbd8d59ea19115dc874eeb2cf294169ac5e0d}"
DIR=third_party/AutoDojo
VENV="${VENV:-.venv-autodojo}"
PY="${PYTHON:-python3}"

if [[ ! -d "$DIR/.git" ]]; then
  git clone https://github.com/xhOwenMa/AutoDojo.git "$DIR"
fi
git -C "$DIR" fetch -q origin "$AUTODOJO_COMMIT" 2>/dev/null || git -C "$DIR" fetch -q origin
if ! git -C "$DIR" diff --quiet; then
  echo "[setup] $DIR 에 로컬 변경이 있어 초기화합니다 (패치 재적용)"; git -C "$DIR" checkout -q -- .
fi
git -C "$DIR" checkout -q "$AUTODOJO_COMMIT"
PATCH="$ROOT/patches/autodojo-ollama.patch"
git -C "$DIR" apply --check "$PATCH"      # 실패하면 set -e 로 중단 (핀 커밋이 바뀌면 패치 갱신 필요)
git -C "$DIR" apply "$PATCH"
echo "[setup] AutoDojo @ $(git -C "$DIR" rev-parse --short HEAD) + patches/autodojo-ollama.patch"

[[ -d "$VENV" ]] || $PY -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -e "$DIR/agentdojo"                 # 포크 (필터 방어까지 쓰려면 "[transformers]")
"$VENV/bin/pip" install -q nltk json_repair numpy pyyaml        # 최적화기 의존성
"$VENV/bin/pip" install -q --no-deps -e .
# 최적화기의 문장 분리용 NLTK 데이터. 프록시 환경이면 NLTK_ALLOW_PROXIED_URLOPEN=1 이 필요할 수 있다.
if ! "$VENV/bin/python" -c "import nltk; nltk.data.find('tokenizers/punkt_tab')" 2>/dev/null; then
  "$VENV/bin/python" -c "import nltk; nltk.download('punkt_tab', quiet=True)" \
    || echo "[setup] !! punkt_tab 다운로드 실패. 프록시 환경이면: NLTK_ALLOW_PROXIED_URLOPEN=1 $VENV/bin/python -c \"import nltk; nltk.download('punkt_tab')\""
fi
"$VENV/bin/python" -c "from agentdojo_ollama.compat import detect_bench; print('[setup] detected bench:', detect_bench())"
echo "[setup] done. 사용: BENCH=autodojo scripts/run_autodojo_transfer.sh / scripts/run_autodojo_optimize.sh"
