# AgentDojo 계열 벤치마크 테스트 계획

작성일: 2026-09-18
대상 모델: `qwen3.8:27b` (Ollama)
Ollama 서버: `http://10.25.36.222:9090`

---

## 0. 목표와 범위

1. **최종 목표**: AgentDojo 계열(프롬프트 인젝션 기반 에이전트 보안 벤치마크)에 대해 로컬 Ollama 모델을 평가할 수 있는 재현 가능한 환경을 만든다.
2. **1차 목표**: 원본 AgentDojo(ethz-spylab/agentdojo)로 `qwen3.8:27b`의 **유틸리티(utility)**, **공격 성공률(ASR)**, **공격 하 유틸리티**를 측정한다.
3. **2차 목표**: 같은 파이프라인을 AgentDojo 파생/계열 벤치마크로 확장한다.

### AgentDojo 계열 후보 (2차 목표에서 다룸)

| 벤치마크 | 성격 | 비고 |
|---|---|---|
| AgentDojo (원본, PyPI `agentdojo` 0.1.35) | 4개 suite(workspace, slack, travel, banking), 97 user task, 27 injection task, 629 공격 케이스 | 1차 대상 |
| AgentDojo-Inspect (UK AISI 포크) | Inspect 프레임워크 이식판, 태스크 버그 수정 + 인젝션 태스크 추가 | `inspect_evals`의 `agentdojo` 태스크 |
| InjecAgent / ASB(Agent Security Bench) / BIPIA | 동일 주제(간접 프롬프트 인젝션)의 유사 벤치마크 | 필요 시 확장 |

---

## 1. 사전 확인 (Phase 0)

이 항목들은 실제 GPU/Ollama 서버가 있는 곳(사내망)에서 수행한다. 이 저장소를 작성한 원격 컨테이너에서는 `10.25.36.222`에 접근이 되지 않았다.

- [ ] **모델 태그 확인**. `qwen3.8:27b`라는 태그가 실제로 서버에 있는지 확인한다. 오타(예: `qwen3:27b`, `qwen3.5:27b`)일 가능성이 있으므로 아래 출력에서 정확한 이름을 확정한다.
  ```bash
  curl -s http://10.25.36.222:9090/api/tags | python3 -m json.tool | grep '"name"'
  ```
- [ ] **OpenAI 호환 엔드포인트 동작 확인** (AgentDojo는 `/v1/chat/completions` + `tools`를 사용).
  ```bash
  curl -s http://10.25.36.222:9090/v1/models
  curl -s http://10.25.36.222:9090/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.8:27b","messages":[{"role":"user","content":"서울 날씨 알려줘"}],
         "tools":[{"type":"function","function":{"name":"get_weather","description":"도시 날씨 조회",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}'
  ```
  응답에 `tool_calls`가 정상적으로 오는지 확인한다. 안 오면 모델이 네이티브 tool calling을 지원하지 않는 것이므로 §5의 대안(B) 경로로 간다.
- [ ] **컨텍스트 길이**. Ollama 기본 `num_ctx`는 4096으로, AgentDojo의 tool 스키마 + 다중 턴 대화에는 부족하다. 서버 측에서 `OLLAMA_CONTEXT_LENGTH=32768` 이상으로 기동하거나, Modelfile로 `num_ctx 32768`을 고정한 파생 태그를 만든다.
  ```
  # Modelfile
  FROM qwen3.8:27b
  PARAMETER num_ctx 32768
  PARAMETER temperature 0
  ```
  ```bash
  ollama create qwen3.8-27b-agentdojo -f Modelfile
  ```
- [ ] **thinking 모드 정책 결정**. Qwen3 계열은 기본 thinking 모드가 켜져 있어 응답 지연이 크고 tool call 파싱에 영향을 줄 수 있다. (a) thinking off, (b) thinking on 두 설정을 각각 별도 실험으로 다루기로 하고, 1차는 **off**로 진행한다. Ollama에서는 시스템 프롬프트에 `/no_think`를 넣거나 서버 옵션 `think=false`를 사용한다.
- [ ] **동시성**. 4개 suite를 병렬로 돌리려면 서버에 `OLLAMA_NUM_PARALLEL=4` 정도가 필요하다. VRAM 여유가 없으면 순차 실행한다.

---

## 2. 환경 구축 (Phase 1)

### 2.1 저장소 구조 (제안)

```
benchmarkTest/
├── PLAN.md                  # 이 문서
├── README.md                # 실행 요약
├── pyproject.toml           # uv/pip 의존성 (agentdojo==0.1.35 고정)
├── .env.example             # OPENAI_COMPATIBLE_BASE_URL 등 템플릿
├── configs/
│   └── qwen3.8-27b.env      # 모델별 설정
├── scripts/
│   ├── check_ollama.sh      # Phase 0 점검 자동화
│   ├── run_smoke.sh         # 단일 태스크 스모크 테스트
│   ├── run_utility.sh       # 공격 없음 전체 실행
│   ├── run_attack.sh        # important_instructions 공격 실행
│   ├── run_defense.sh       # 방어 기법별 실행
│   └── summarize.py         # runs/ 결과 집계 → CSV/Markdown
├── runs/                    # AgentDojo 로그 출력 (gitignore)
└── results/                 # 집계 결과 (커밋 대상)
```

### 2.2 설치

```bash
# Python 3.10+ 필요
uv venv && source .venv/bin/activate
uv pip install "agentdojo==0.1.35"
# 방어 기법 transformers_pi_detector 사용 시
uv pip install "agentdojo[transformers]"
```

### 2.3 모델 연결 설정

AgentDojo 0.1.35에는 `openai-compatible` 프로바이더가 있어 Ollama의 OpenAI 호환 API에 바로 연결할 수 있다. `.env` 파일:

```dotenv
OPENAI_COMPATIBLE_BASE_URL=http://10.25.36.222:9090/v1
OPENAI_COMPATIBLE_API_KEY=ollama        # Ollama는 키를 검사하지 않지만 빈 값이면 AgentDojo가 에러를 냄
```

실행 시 `--model openai-compatible --model-id qwen3.8:27b`를 준다. `--model-id`는 필수다.

---

## 3. 스모크 테스트 (Phase 2)

목적: 파이프라인이 끝까지 도는지, tool call이 정상 파싱되는지 확인.

```bash
python -m agentdojo.scripts.benchmark \
  --model openai-compatible --model-id qwen3.8:27b \
  -s workspace -ut user_task_0 -ut user_task_1 \
  --logdir ./runs
```

확인 사항:
- `runs/openai-compatible/workspace/.../user_task_0/none/none.json` 로그 생성 여부
- 로그의 `messages`에 `tool_calls`와 `tool` 역할 메시지가 교대로 나오는지
- utility가 True/False로 판정되는지(예외로 중단되지 않는지)
- 한 태스크당 소요 시간 → 전체 실행 시간 추정에 사용

공격 포함 스모크 테스트:

```bash
python -m agentdojo.scripts.benchmark \
  --model openai-compatible --model-id qwen3.8:27b \
  -s workspace -ut user_task_0 -it injection_task_0 \
  --attack important_instructions --logdir ./runs
```

---

## 4. 본 실험 (Phase 3)

AgentDojo 논문의 표준 리포팅 항목을 그대로 따른다. 벤치마크 버전은 기본값 `v1.2.2`를 사용하고 결과에 명시한다.

| 실험 | 명령 핵심 옵션 | 측정치 |
|---|---|---|
| E1. 유틸리티(공격 없음) | `--attack` 없음, 전체 suite | Utility (97 태스크) |
| E2. 공격 하 성능 | `--attack important_instructions` | Targeted ASR, Utility under attack (629 케이스) |
| E3. 공격 변형 | `tool_knowledge`, `important_instructions_no_names` 등 | ASR 비교 |
| E4. 방어 | `--defense tool_filter` / `repeat_user_prompt` / `spotlighting_with_delimiting` / `transformers_pi_detector` | 방어별 Utility·ASR |

실행 예:

```bash
# E1
python -m agentdojo.scripts.benchmark --model openai-compatible --model-id qwen3.8:27b \
  --max-workers 4 --logdir ./runs
# E2
python -m agentdojo.scripts.benchmark --model openai-compatible --model-id qwen3.8:27b \
  --attack important_instructions --max-workers 4 --logdir ./runs
# E4 (예: tool_filter)
python -m agentdojo.scripts.benchmark --model openai-compatible --model-id qwen3.8:27b \
  --attack important_instructions --defense tool_filter --max-workers 4 --logdir ./runs
```

`--max-workers`는 suite 단위 병렬이므로 최대 4가 의미 있다. 이미 완료된 태스크는 건너뛰므로 중단 후 재실행이 가능하고, 다시 돌리려면 `-f`를 준다.

### 실행 시간 추정

27B 모델을 단일 GPU에서 서빙하면 태스크당 수십 초에서 수 분이 걸린다. E2 한 번(629 케이스 × 다중 턴)은 수 시간에서 하루 단위로 잡고, 스모크 테스트에서 측정한 태스크당 시간으로 재추정한다.

---

## 5. 위험 요소와 대안

- **(A) 모델 태그 불일치**: `qwen3.8:27b`가 없으면 Phase 0에서 확정한 실제 태그로 `configs/`를 수정한다.
- **(B) 네이티브 tool calling 실패**: Ollama의 OpenAI 호환 API가 tool_calls를 반환하지 않거나 파싱이 불안정하면 AgentDojo의 `local` 프로바이더(`LocalLLM`, 프롬프트 기반 tool 포맷)를 쓴다. 이 프로바이더는 `localhost:$LOCAL_LLM_PORT`로 고정되어 있으므로 포트 포워딩으로 우회한다.
  ```bash
  ssh -N -L 8000:10.25.36.222:9090 <점프호스트>   # 또는 socat
  LOCAL_LLM_PORT=8000 python -m agentdojo.scripts.benchmark --model local --model-id qwen3.8:27b ...
  ```
- **(C) 컨텍스트 초과**: 응답이 잘리거나 tool 스키마를 무시하면 `num_ctx`를 늘린다(§1).
- **(D) thinking 토큰이 content에 섞임**: `<think>` 블록이 응답 본문에 들어오면 utility 판정에 영향을 줄 수 있다. thinking off로 고정하거나, 커스텀 파이프라인 요소에서 제거한다.
- **(E) 재현성**: temperature 0, 벤치마크 버전, agentdojo 버전, Ollama 버전, 모델 digest를 `results/`에 함께 기록한다.

---

## 6. 결과 정리 (Phase 4)

- `scripts/summarize.py`가 `runs/` 아래 JSON을 읽어 suite별·전체 Utility / ASR / Utility-under-attack 표를 `results/<model>_<date>.md`와 CSV로 생성한다.
- 공식 리더보드(agentdojo.spylab.ai/results)의 GPT-4o, Claude 등 수치와 나란히 비교표를 만든다.

---

## 7. 계열 벤치마크 확장 (Phase 5)

1. **AgentDojo-Inspect**: `inspect_ai` + `inspect_evals` 설치 후 `inspect eval inspect_evals/agentdojo --model openai-api/ollama/qwen3.8:27b` 형태로 실행. Inspect는 `OPENAI_API_BASE_URL` 방식의 OpenAI 호환 모델을 지원하므로 같은 Ollama 서버를 재사용한다.
2. 원본 AgentDojo와 Inspect판의 태스크 차이(버그 수정, 추가 인젝션 태스크)를 결과에 분리 기록한다.
3. 여유가 되면 InjecAgent / ASB로 동일 모델을 평가해 벤치마크 간 ASR 경향을 비교한다.

---

## 8. 진행 순서 요약

1. Phase 0 점검 스크립트 작성 및 사내망에서 실행 → 모델 태그·tool calling·num_ctx 확정
2. Phase 1 저장소 스캐폴딩(pyproject, .env.example, scripts/) 커밋
3. Phase 2 스모크 테스트 통과
4. Phase 3 E1 → E2 → E4 순으로 실행, 각 단계 결과를 `results/`에 커밋
5. Phase 4 집계 스크립트와 비교표
6. Phase 5 AgentDojo-Inspect로 확장
