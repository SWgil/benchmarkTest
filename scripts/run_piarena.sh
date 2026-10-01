#!/usr/bin/env bash
# PIArena 비-에이전트 정적 데이터셋 평가를 원격 Ollama 모델에 돌린다 (main.py).
# 측정 대상: 방어 없는 상태의 LLM 자체 IPI 저항성 — 이 저장소의 기존 목적과 동일.
#
# 범위 (사용자 요청):
#   - AgentDojo / AgentDyn 에이전트 벤치마크 제외: main_agentdojo.py 를 호출하지 않는다.
#     (그 두 가지는 기존 BENCH=agentdojo / BENCH=agentdyn 트랙으로 이미 돌린다.)
#   - 적응형 공격(strategy_search/pair/tap/nanogcg, main_search.py)은 기본에서 제외.
#     테스트 결과를 본 뒤 결정. ATTACK 에 그 이름을 주면 거부한다.
#
# 변수:
#   CONFIG   기본 configs/qwen3.8-27b.env (.env 가 있으면 덮어씀)   — OLLAMA_BASE_URL/MODEL/API_KEY
#   DATASETS 기본 비-에이전트 13종. 공백 구분 파일 stem 으로 덮어쓰기 가능.
#   ATTACK   기본 combined. 허용: none direct ignore completion character combined (정적 only)
#   DEFENSE  기본 none. (방어 실험을 하려면 PIARENA_FULL_INSTALL 로 설치 후 이름 지정)
#   NAME     실험 이름(결과 폴더). 기본 qwen 모델명+날짜.
#   SEED     기본 42.
#   REASONING_EFFORT 기본 none (Ollama thinking off). 빈 값이면 모델 기본값.
#   TEMPERATURE      기본 0.0 (명시 전송).
#   PIARENA_JUDGE_MODEL  기본 openai/ollama (심판도 같은 Ollama 엔드포인트). 로컬 HF 심판을 쓰려면 HF 경로.
#
# 예: ATTACK=direct DATASETS="squad_v2 nq_rag" scripts/run_piarena.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

CONFIG="${CONFIG:-configs/qwen3.8-27b.env}"
if [[ -f "$CONFIG" ]]; then set -a; source "$CONFIG"; set +a; fi
if [[ -f .env ]]; then set -a; source .env; set +a; fi
: "${OLLAMA_BASE_URL:?OLLAMA_BASE_URL is not set (see .env.example)}"
: "${OLLAMA_MODEL:?OLLAMA_MODEL is not set (see .env.example)}"

DIR=third_party/PIArena
VENV="${VENV:-.venv-piarena}"
[[ -d "$VENV" ]] || { echo "venv '$VENV' 없음. scripts/setup_piarena.sh 먼저." >&2; exit 1; }
[[ -d "$DIR" ]]  || { echo "$DIR 없음. scripts/setup_piarena.sh 먼저." >&2; exit 1; }
# shellcheck disable=SC1091
source "$VENV/bin/activate"

ATTACK="${ATTACK:-combined}"
case "$ATTACK" in
  none|direct|ignore|completion|character|combined) ;;
  strategy_search|pair|tap|nanogcg)
    echo "!! '$ATTACK' 는 적응형 공격이라 이 스크립트 범위 밖입니다 (테스트 결과 후 결정)." >&2
    echo "   필요해지면 main_search.py 로 별도 구성하세요 (--attacker_llm 필요)." >&2
    exit 2 ;;
  *) echo "!! 알 수 없는 ATTACK='$ATTACK'. 정적 공격만: none direct ignore completion character combined" >&2; exit 2 ;;
esac
DEFENSE="${DEFENSE:-none}"
SEED="${SEED:-42}"
NAME="${NAME:-piarena_$(echo "$OLLAMA_MODEL" | tr ':/' '--')_$(date +%Y%m%d)}"
REASONING_EFFORT="${REASONING_EFFORT:-none}"
TEMPERATURE="${TEMPERATURE:-0.0}"

# 비-에이전트 정적 데이터셋 13종 (논문 Table 8). knowledge_corruption 3종은 opt-in.
DEFAULT_DATASETS="squad_v2 dolly_closed_qa dolly_information_extraction dolly_summarization \
nq_rag msmarco_rag hotpotqa_rag \
hotpotqa_long qasper_long gov_report_long multi_news_long passage_retrieval_en_long lcc_long"
DATASETS="${DATASETS:-$DEFAULT_DATASETS}"

# Ollama 를 OpenAI 호환 백엔드로 쓰는 config 생성 (backend_llm=openai/ollama → ollama.yaml).
mkdir -p "$DIR/configs/openai_configs"
cat > "$DIR/configs/openai_configs/ollama.yaml" <<YAML
model: "$OLLAMA_MODEL"
base_url: "$OLLAMA_BASE_URL"
api_key: "${OLLAMA_API_KEY:-ollama}"
reasoning_effort: "$REASONING_EFFORT"
temperature: $TEMPERATURE
strip_thinking: true
YAML

export PIARENA_ALLOW_NO_GPU="${PIARENA_ALLOW_NO_GPU:-1}"
export PIARENA_JUDGE_MODEL="${PIARENA_JUDGE_MODEL:-openai/ollama}"

echo "[run_piarena] model=$OLLAMA_MODEL base_url=$OLLAMA_BASE_URL attack=$ATTACK defense=$DEFENSE"
echo "[run_piarena] judge=$PIARENA_JUDGE_MODEL name=$NAME datasets=[$DATASETS]"

cd "$DIR"
rc=0
for ds in $DATASETS; do
  path="datasets/${ds}.json"
  if [[ ! -f "$path" ]]; then echo "!! 데이터셋 없음: $path (건너뜀)"; continue; fi
  echo "### PIArena dataset=$ds attack=$ATTACK defense=$DEFENSE"
  python main.py \
    --dataset "$path" \
    --backend_llm openai/ollama \
    --attack "$ATTACK" \
    --defense "$DEFENSE" \
    --name "$NAME" \
    --seed "$SEED" "$@" || { echo "!! $ds 실행 실패 (rc=$?)"; rc=1; }
done
echo "[run_piarena] 결과: $DIR/results/evaluation_results/$NAME/"
exit $rc
