# 로컬 Ollama 서버 환경 가정

다른 저장소에서 LLM 실험을 할 때 공통으로 쓰는 **로컬 Ollama 서버에 대한 가정**을 모아 둔 브랜치입니다. 벤치마크 코드는 포함하지 않습니다. 이 브랜치를 참조하는 세션은 아래 내용을 그대로 전제하고 작업하면 됩니다.

## 1. 서버

| 항목 | 값 |
|---|---|
| 서버 | Ollama, `http://10.251.36.222:9090` (사내망) |
| OpenAI 호환 엔드포인트 | `http://10.251.36.222:9090/v1` (`/v1/chat/completions`, `/v1/models`) |
| Ollama native API | `http://10.251.36.222:9090/api/...` (`/api/tags`, `/api/show`, `/api/version`) |
| API 키 | 검사하지 않음. openai 클라이언트가 빈 값을 거부하므로 더미 값(`ollama`) 사용 |
| 접근 범위 | 사내망에서만 접근 가능. 원격 컨테이너(claude.ai/code 등)에서는 접근되지 않으므로 실제 호출은 사내망에서 수행하고, 원격에서는 모의 서버로 파이프라인만 검증한다 |

## 2. 모델

| 항목 | 값 |
|---|---|
| 모델 태그 | `qwen3.8:27b` (Qwen3 계열, 27B) |
| 태그 확정 | 이 태그는 **실제 존재 여부가 확인되지 않았다**. 오타(`qwen3:27b`, `qwen3.5:27b` 등)일 수 있으므로 `check_ollama.sh` 2번 항목으로 확정한 뒤 `.env` 를 수정한다 |
| 공격/프롬프트에서 부르는 이름 | `Qwen` |
| tool calling | OpenAI 호환 API의 네이티브 `tools` / `tool_calls` 를 사용한다고 가정. `check_ollama.sh` 4번 항목으로 확인 |
| 컨텍스트 길이 | **`num_ctx` 32768 이상 필요.** Ollama 기본값 4096은 tool 스키마 + 다중 턴 대화에 부족하다. 서버를 `OLLAMA_CONTEXT_LENGTH=32768` 로 기동하거나 `Modelfile.qwen3.8-27b` 로 파생 태그를 만든다 |
| thinking | 기본은 **off**. 매 요청에 `reasoning_effort: "none"` (Ollama가 `think=false` 로 매핑) 을 보내고 시스템 프롬프트 끝에 `/no_think` 를 붙인다. 그래도 `<think>...</think>` 가 content 에 섞이면 클라이언트에서 제거한다. 구형 Ollama 는 `reasoning_effort` 를 무시하므로 `check_ollama.sh` 4번에서 실제로 꺼지는지 확인 |
| 재현성 | 매 요청에 `temperature: 0`, `seed: 0` 을 **명시 전송**한다 (일부 클라이언트는 0을 "미지정"으로 취급해 보내지 않으므로 주의) |
| 동시성 | 병렬 요청은 서버의 `OLLAMA_NUM_PARALLEL` (예: 4) 에 맞춘다. VRAM 여유가 없으면 순차 실행 |
| 속도 | 27B 모델 단일 GPU 기준, 다중 턴 tool calling 태스크 하나에 수십 초에서 수 분 |

## 3. 클라이언트 설정

`.env.example` 을 `.env` 로 복사해서 사용합니다.

```dotenv
OLLAMA_BASE_URL=http://10.251.36.222:9090/v1
OLLAMA_API_KEY=ollama
OLLAMA_MODEL=qwen3.8:27b
```

openai 파이썬 클라이언트 예:

```python
import openai, os
client = openai.OpenAI(base_url=os.environ["OLLAMA_BASE_URL"], api_key=os.environ["OLLAMA_API_KEY"])
resp = client.chat.completions.create(
    model=os.environ["OLLAMA_MODEL"],
    messages=[{"role": "system", "content": "You are a helpful assistant. /no_think"},
              {"role": "user", "content": "..."}],
    tools=[...],
    temperature=0, seed=0,
    reasoning_effort="none",   # Ollama: think=false
)
```

curl 예:

```bash
curl -s http://10.251.36.222:9090/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model":"qwen3.8:27b","temperature":0,"seed":0,"reasoning_effort":"none",
  "messages":[{"role":"user","content":"서울 날씨 알려줘 /no_think"}],
  "tools":[{"type":"function","function":{"name":"get_weather","description":"도시 날씨 조회",
    "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}'
```

## 4. 점검

사내망에서 실행합니다.

```bash
cp .env.example .env
./check_ollama.sh
```

확인 항목: 서버 버전, 모델 태그 존재, `num_ctx` / 최대 컨텍스트 / capabilities, OpenAI 호환 tool calling 과 `reasoning_effort=none` 적용 여부.

`num_ctx` 가 32768 미만이면 서버에서 파생 태그를 만듭니다.

```bash
ollama create qwen3.8-27b-ctx32k -f Modelfile.qwen3.8-27b
# 이후 .env 의 OLLAMA_MODEL=qwen3.8-27b-ctx32k
```

## 5. 대안 (tool calling 이 안 될 때)

OpenAI 호환 API 가 `tool_calls` 를 돌려주지 않으면 프롬프트 기반 tool 포맷(예: AgentDojo `local` 프로바이더)으로 우회합니다. 그런 프로바이더는 보통 `localhost` 고정이므로 포트 포워딩으로 붙입니다.

```bash
ssh -N -L 8000:10.251.36.222:9090 <점프호스트>   # 또는 socat
```

## 파일

| 파일 | 내용 |
|---|---|
| `README.md` | 이 문서 |
| `.env.example` | 클라이언트 환경변수 템플릿 |
| `check_ollama.sh` | 서버·모델·tool calling·thinking 점검 스크립트 |
| `Modelfile.qwen3.8-27b` | `num_ctx 32768` 파생 태그용 Modelfile |
