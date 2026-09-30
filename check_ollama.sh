#!/usr/bin/env bash
# 로컬 Ollama 서버 점검. 서버 접속, 모델 태그 존재 여부, num_ctx, OpenAI 호환 API의 tool calling, thinking off 를 확인한다.
# 사용법: cp .env.example .env && ./check_ollama.sh   (또는 OLLAMA_BASE_URL=... OLLAMA_MODEL=... ./check_ollama.sh)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ -f .env ]]; then set -a; source .env; set +a; fi
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://10.251.36.222:9090/v1}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.8:27b}"
HOST="${OLLAMA_BASE_URL%/v1}"

echo "== 1. 서버 버전 ($HOST)"
curl -sf "$HOST/api/version" || { echo "서버 접속 실패: $HOST"; exit 1; }; echo
echo "== 2. 설치된 모델 태그"
curl -sf "$HOST/api/tags" | python3 -c 'import json,sys; [print(" -", m["name"]) for m in json.load(sys.stdin)["models"]]'
if ! curl -sf "$HOST/api/tags" | grep -q "\"name\":\"$OLLAMA_MODEL\""; then
  echo "!! '$OLLAMA_MODEL' 태그가 없습니다. 위 목록에서 정확한 이름을 골라 .env 의 OLLAMA_MODEL 을 수정하세요."; exit 1
fi
echo "== 3. 모델 파라미터 (num_ctx 확인)"
curl -sf "$HOST/api/show" -d "{\"name\":\"$OLLAMA_MODEL\"}" | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(" parameters:", d.get("parameters","(none)").replace("\n","; "))
ctx=[ (k,v) for k,v in d.get("model_info",{}).items() if k.endswith("context_length")]
print(" model max context:", ctx)
print(" capabilities:", d.get("capabilities"))'
echo "== 4. OpenAI 호환 tool calling + reasoning_effort=none"
curl -sf "$OLLAMA_BASE_URL/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\":\"$OLLAMA_MODEL\",\"temperature\":0,\"reasoning_effort\":\"none\",
  \"messages\":[{\"role\":\"system\",\"content\":\"You are a helpful assistant. /no_think\"},{\"role\":\"user\",\"content\":\"What is the weather in Seoul? Use the tool.\"}],
  \"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",\"description\":\"Get weather for a city\",
   \"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}]}" \
 | python3 -c '
import json,sys; d=json.load(sys.stdin); m=d["choices"][0]["message"]
print(" tool_calls:", m.get("tool_calls")); print(" content:", (m.get("content") or "")[:200]); print(" reasoning:", (m.get("reasoning") or "")[:100] or "(none)")
ok = bool(m.get("tool_calls")); print(" => tool calling", "OK" if ok else "FAILED")'
echo "== 완료. num_ctx 가 32768 미만이면 Modelfile.qwen3.8-27b 로 파생 태그를 만드세요 (README 참고)."
