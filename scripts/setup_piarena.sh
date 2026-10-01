#!/usr/bin/env bash
# PIArena (sleeepeer/PIArena, ACL 2026) 를 third_party/ 에 받고 Ollama 패치를 적용한 뒤
# 전용 venv(.venv-piarena)에 설치한다. 이 저장소는 PIArena의 "비-에이전트 정적 데이터셋"
# 평가(main.py)만 쓴다. AgentDojo/AgentDyn 통합(main_agentdojo.py)은 기존 BENCH=agentdojo/
# agentdyn 와 겹치므로 제외하고, 적응형(strategy_search/pair/tap/nanogcg, main_search.py)은
# 테스트 결과를 본 뒤 결정하기로 하여 기본 설치/실행 범위에서 뺀다.
#
# 패치 내용 (patches/piarena-ollama.patch):
#   - OpenAIModel 에 base_url/temperature/reasoning_effort/<think> 제거 추가 → 원격 Ollama 지정
#   - main.py 의 GPU 강제(assert cuda>0) 를 PIARENA_ALLOW_NO_GPU=1 일 때 건너뜀
#   - llm_judge 기본 심판 모델을 PIARENA_JUDGE_MODEL 환경변수로 (원격 백엔드로 지정 가능)
#   - defenses 레지스트리를 lazy-import 로 변경 → --defense none 이 vllm/fastchat/peft/spacy 없이 import
#
# 기본은 "원격 Ollama + 정적 공격 + 방어 없음" 에 필요한 가벼운 의존성만 설치한다.
# 로컬 HF 모델/방어까지 쓰려면 PIARENA_FULL_INSTALL=1 로 requirements.txt 전체를 설치한다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PIARENA_COMMIT="${PIARENA_COMMIT:-8bd7a89e4a88d64b8354d9aa80a684923be6b795}"
DIR=third_party/PIArena
VENV="${VENV:-.venv-piarena}"
PY="${PYTHON:-python3}"

if [[ ! -d "$DIR/.git" ]]; then
  git clone https://github.com/sleeepeer/PIArena.git "$DIR"
fi
git -C "$DIR" fetch -q origin "$PIARENA_COMMIT" 2>/dev/null || git -C "$DIR" fetch -q origin
if ! git -C "$DIR" diff --quiet; then
  echo "[setup] $DIR 에 로컬 변경이 있어 초기화합니다 (패치 재적용)"; git -C "$DIR" checkout -q -- .
fi
git -C "$DIR" checkout -q "$PIARENA_COMMIT"
PATCH="$ROOT/patches/piarena-ollama.patch"
git -C "$DIR" apply --check "$PATCH"      # 실패하면 set -e 로 중단 (핀 커밋이 바뀌면 패치 갱신 필요)
git -C "$DIR" apply "$PATCH"
echo "[setup] PIArena @ $(git -C "$DIR" rev-parse --short HEAD) + patches/piarena-ollama.patch"

[[ -d "$VENV" ]] || $PY -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q -e "$DIR"      # piarena 패키지 등록 (pyproject 에 deps 없음)

if [[ "${PIARENA_FULL_INSTALL:-0}" == "1" ]]; then
  echo "[setup] PIARENA_FULL_INSTALL=1 → requirements.txt 전체 설치 (vllm/fastchat 등 GPU 의존성 포함)"
  "$VENV/bin/pip" install -q -r "$DIR/requirements.txt"
else
  # 원격 Ollama + 정적 공격 + 방어 없음(main.py) 에 필요한 import-time 의존성만.
  # torch 는 main.py/llm.py 가 최상단에서 import 하므로 필수(원격이라도). GPU 박스면 기본 wheel,
  # CPU 전용이면: PIP_TORCH_EXTRA="--index-url https://download.pytorch.org/whl/cpu" 로 넘긴다.
  # shellcheck disable=SC2086
  "$VENV/bin/pip" install -q ${PIP_TORCH_EXTRA:-} torch
  "$VENV/bin/pip" install -q \
    transformers openai "google-genai" anthropic datasets pyyaml tqdm \
    numpy rouge fuzzywuzzy python-Levenshtein jieba
fi

# 샌티티: 패치 마커 + 데이터셋 존재 확인 (torch 가 있으면 import 체크까지)
grep -q "base_url" "$DIR/piarena/llm.py" && echo "[setup] llm.py base_url 패치 확인"
n=$(ls "$DIR"/datasets/*.json 2>/dev/null | wc -l); echo "[setup] datasets JSON: $n 개"
PIARENA_ALLOW_NO_GPU=1 "$VENV/bin/python" - <<'PYCHK' 2>/dev/null && echo "[setup] import OK (attacks/defense none)" || echo "[setup] (import 체크 생략: torch 미설치 또는 환경 문제 - 실제 실행 시 재확인)"
import piarena
from piarena.attacks import get_attack
from piarena.defenses import get_defense
get_attack("combined"); get_defense("none")
PYCHK
echo "[setup] done. 사용: scripts/run_piarena.sh"
