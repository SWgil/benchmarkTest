# AgentDojo 계열 벤치마크 테스트 계획

작성일: 2026-09-18
대상 모델: `qwen3.8:27b` (Ollama)
Ollama 서버: `http://10.251.36.222:9090`

---

## 0. 목표와 범위

1. **최종 목표**: AgentDojo 계열(프롬프트 인젝션 기반 에이전트 보안 벤치마크)에 대해 로컬 Ollama 모델을 평가할 수 있는 재현 가능한 환경을 만든다.
2. **1차 목표**: 원본 AgentDojo(ethz-spylab/agentdojo)로 `qwen3.8:27b`의 **유틸리티(utility)**, **공격 성공률(ASR)**, **공격 하 유틸리티**를 측정한다.
3. **2차 목표**: 같은 파이프라인을 AgentDojo 파생/계열 벤치마크로 확장한다.

### AgentDojo 계열 후보 (2차 목표에서 다룸)

| 벤치마크 | 성격 | 비고 |
|---|---|---|
| AgentDojo (원본, PyPI `agentdojo` 0.1.35) | 4개 suite(workspace, slack, travel, banking), 97 user task, 27 injection task, 629 공격 케이스 | 1차 대상 |
| AgentDyn (SaFo-Lab/AgentDyn, arXiv 2602.03117) | AgentDojo 포크. 개방형 suite 3개(shopping, github, dailylife) 60 user task, 560 케이스 추가 | 2차 대상, 구현됨 (`BENCH=agentdyn`) |
| AutoDojo (xhOwenMa/AutoDojo, arXiv 2606.15057) | AgentDojo 포크. 공격자 LLM이 방어를 상대로 인젝션을 반복 최적화하는 적응형 공격 + 논문 캐시 | 2차 대상, 구현됨 (`BENCH=autodojo`) |
| AgentDojo-Inspect (UK AISI 포크) | Inspect 프레임워크 이식판, 태스크 버그 수정 + 인젝션 태스크 추가 | `inspect_evals`의 `agentdojo` 태스크 |
| InjecAgent / ASB(Agent Security Bench) / BIPIA | 동일 주제(간접 프롬프트 인젝션)의 유사 벤치마크 | 필요 시 확장 |

---

## 1. 사전 확인 (Phase 0)

이 항목들은 실제 GPU/Ollama 서버가 있는 곳(사내망)에서 수행한다. 이 저장소를 작성한 원격 컨테이너에서는 `10.251.36.222`에 접근이 되지 않았다.

- [ ] **모델 태그 확인**. `qwen3.8:27b`라는 태그가 실제로 서버에 있는지 확인한다. 오타(예: `qwen3:27b`, `qwen3.5:27b`)일 가능성이 있으므로 아래 출력에서 정확한 이름을 확정한다.
  ```bash
  curl -s http://10.251.36.222:9090/api/tags | python3 -m json.tool | grep '"name"'
  ```
- [ ] **OpenAI 호환 엔드포인트 동작 확인** (AgentDojo는 `/v1/chat/completions` + `tools`를 사용).
  ```bash
  curl -s http://10.251.36.222:9090/v1/models
  curl -s http://10.251.36.222:9090/v1/chat/completions \
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

### 2.1 저장소 구조 (구현됨)

```
benchmarkTest/
├── PLAN.md                    # 이 문서
├── README.md                  # 실행 요약
├── pyproject.toml             # agentdojo==0.1.35 고정, 엔트리포인트 agentdojo-ollama / agentdojo-summarize
├── .env.example               # OLLAMA_BASE_URL / OLLAMA_MODEL 템플릿
├── agentdojo_ollama/
│   ├── llm.py                 # OllamaLLM: OpenAILLM 상속, temperature/seed/reasoning_effort 명시 전송, <think> 제거
│   ├── run.py                 # 원본 benchmark CLI와 동일 옵션의 러너
│   └── summarize.py           # runs/ 집계 → Markdown/CSV
├── configs/
│   ├── qwen3.8-27b.env        # 모델별 설정
│   └── Modelfile.qwen3.8-27b  # num_ctx 32768 파생 태그용
├── scripts/
│   ├── common.sh              # configs/ + .env 로드
│   ├── check_ollama.sh        # Phase 0 점검 자동화
│   ├── run_smoke.sh           # Phase 2
│   ├── run_utility.sh         # E1
│   ├── run_attack.sh          # E2/E3
│   ├── run_defense.sh         # E4
│   ├── summarize.sh           # Phase 4
│   └── run_inspect.sh         # Phase 5 (AgentDojo-Inspect)
├── runs/                      # AgentDojo 로그 (gitignore)
└── results/                   # 집계 결과 (커밋 대상)
```

### 2.2 설치

```bash
uv venv && source .venv/bin/activate
uv pip install -e .                  # agentdojo 0.1.35 + 러너
uv pip install -e ".[transformers]"  # transformers_pi_detector 방어 사용 시
uv pip install -e ".[inspect]"       # Phase 5
cp .env.example .env
```

### 2.3 모델 연결 방식 (중요한 변경)

계획 초안에서는 AgentDojo의 `openai-compatible` 프로바이더를 쓰려 했으나, **PyPI 배포판 0.1.35에는 이 프로바이더가 없다** (GitHub main에만 존재). 또한 원본 `OpenAILLM`은 `temperature or NOT_GIVEN` 구현 때문에 temperature 0을 실제로 보내지 않는다. 그래서 다음을 자체 구현했다.

- `OllamaLLM(OpenAILLM)`: base_url을 Ollama 서버로 설정한 클라이언트로 `/v1/chat/completions` 호출. 매 요청에 `temperature=0`, `seed=0`, `reasoning_effort="none"`(Ollama가 think=false로 매핑)을 명시 전송하고, 응답의 `<think>` 블록을 제거한다. `OpenAILLM`을 상속하므로 `tool_filter` 방어도 그대로 동작한다.
- `agentdojo_ollama.run`: `PipelineConfig(llm=OllamaLLM(...))`로 파이프라인을 만들고 원본의 `benchmark_suite_with(out)_injections`를 호출. 공격 문구가 모델을 지칭할 수 있도록 `MODEL_NAMES`에 모델 태그 → `Qwen`을 등록한다.
- 시스템 메시지 끝에 Qwen3 soft switch `/no_think`를 붙인다 (`--no-no-think-tag`로 끌 수 있음).

`.env`:

```dotenv
OLLAMA_BASE_URL=http://10.251.36.222:9090/v1
OLLAMA_API_KEY=ollama
OLLAMA_MODEL=qwen3.8:27b
MODEL_PROSE_NAME=Qwen
```

실행: `agentdojo-ollama --model qwen3.8:27b --base-url http://10.251.36.222:9090/v1 ...` 또는 `scripts/*.sh`.

### 2.4 검증 상태

이 저장소를 만든 원격 컨테이너에서는 실제 서버에 접근할 수 없어, Ollama의 OpenAI 호환 API를 흉내내는 모의 서버(첫 턴 tool call, 이후 `<think>` 포함 텍스트 응답)로 다음을 확인했다.

- 공격 없음 / `important_instructions` 공격 / `tool_filter` 방어 실행이 끝까지 돌고 원본과 같은 경로에 로그가 생성됨
- 요청에 `temperature=0.0`, `seed=0`, `reasoning_effort="none"`이 전송되고 시스템 메시지에 `/no_think`가 붙음
- 응답의 `<think>` 블록이 로그에서 제거됨, 인젝션 문구에 모델 이름 `Qwen`이 들어감
- `--max-workers 2`로 suite 병렬 실행, `agentdojo-summarize` 집계 표 생성

실제 모델 동작(tool call 파싱 품질, num_ctx, thinking off 적용 여부)은 사내망에서 `scripts/check_ollama.sh`와 `scripts/run_smoke.sh`로 확인해야 한다.

## 3. 스모크 테스트 (Phase 2)

목적: 파이프라인이 끝까지 도는지, tool call이 정상 파싱되는지 확인.

```bash
scripts/run_smoke.sh
# 또는
agentdojo-ollama --model qwen3.8:27b -s workspace -ut user_task_0 -ut user_task_1 --logdir ./runs
```

확인 사항:
- `runs/openai-compatible/workspace/.../user_task_0/none/none.json` 로그 생성 여부
- 로그의 `messages`에 `tool_calls`와 `tool` 역할 메시지가 교대로 나오는지
- utility가 True/False로 판정되는지(예외로 중단되지 않는지)
- 한 태스크당 소요 시간 → 전체 실행 시간 추정에 사용

공격 포함 스모크 테스트:

```bash
agentdojo-ollama --model qwen3.8:27b -s workspace -ut user_task_0 -it injection_task_0 \
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
MAX_WORKERS=4 scripts/run_utility.sh                      # E1
MAX_WORKERS=4 scripts/run_attack.sh                       # E2
ATTACK=tool_knowledge MAX_WORKERS=4 scripts/run_attack.sh # E3
DEFENSES="tool_filter repeat_user_prompt spotlighting_with_delimiting" scripts/run_defense.sh  # E4
```

`--max-workers`는 suite 단위 병렬이므로 최대 4가 의미 있다. 이미 완료된 태스크는 건너뛰므로 중단 후 재실행이 가능하고, 다시 돌리려면 `-f`를 준다.

### 실행 시간 추정

27B 모델을 단일 GPU에서 서빙하면 태스크당 수십 초에서 수 분이 걸린다. E2 한 번(629 케이스 × 다중 턴)은 수 시간에서 하루 단위로 잡고, 스모크 테스트에서 측정한 태스크당 시간으로 재추정한다.

---

## 5. 위험 요소와 대안

- **(A) 모델 태그 불일치**: `qwen3.8:27b`가 없으면 Phase 0에서 확정한 실제 태그로 `configs/`를 수정한다.
- **(B) 네이티브 tool calling 실패**: Ollama의 OpenAI 호환 API가 tool_calls를 반환하지 않거나 파싱이 불안정하면 AgentDojo의 `local` 프로바이더(`LocalLLM`, 프롬프트 기반 tool 포맷)를 쓴다. 이 프로바이더는 `localhost:$LOCAL_LLM_PORT`로 고정되어 있으므로 포트 포워딩으로 우회한다.
  ```bash
  ssh -N -L 8000:10.251.36.222:9090 <점프호스트>   # 또는 socat
  LOCAL_LLM_PORT=8000 python -m agentdojo.scripts.benchmark --model local --model-id qwen3.8:27b ...
  ```
  이 경로는 `runs/local/...`에 로그를 남기므로 집계 시 pipeline 이름이 달라진다.
- **(C) 컨텍스트 초과**: 응답이 잘리거나 tool 스키마를 무시하면 `num_ctx`를 늘린다(§1).
- **(D) thinking 토큰이 content에 섞임**: 러너가 `reasoning_effort=none` + `/no_think`로 끄고, 그래도 섞이면 `<think>` 블록을 제거한다. 구형 Ollama는 `reasoning_effort`를 무시하므로 `check_ollama.sh` 4번 항목에서 실제로 꺼지는지 확인한다.
- **(E) 재현성**: `scripts/summarize.sh`가 Ollama 버전, 모델 digest, agentdojo 버전, 추가 인자를 결과 파일에 기록한다. 벤치마크 버전은 `v1.2.2` 고정.

---

## 6. 결과 정리 (Phase 4)

- `agentdojo-summarize`(`scripts/summarize.sh`)가 `runs/` 아래 JSON을 읽어 pipeline×attack×suite별·전체 Utility / Targeted ASR / 인젝션 태스크 해결 수 / 오류 수 / 평균 소요 시간을 `results/<model>_<date>.md`와 CSV로 생성한다.
- 공식 리더보드(agentdojo.spylab.ai/results)의 GPT-4o, Claude 등 수치와 나란히 비교표를 만든다.

---

## 7. 계열 벤치마크 확장 (Phase 5)

### 7.1 AgentDyn / AutoDojo (구현됨)

두 벤치마크는 모두 `agentdojo` 패키지를 같은 이름으로 수정한 포크라서 venv를 분리한다 (`.venv-agentdyn`, `.venv-autodojo`). `scripts/setup_agentdyn.sh`, `scripts/setup_autodojo.sh`가 핀 커밋(AgentDyn `5353cf7`, AutoDojo `abbcbd8`)으로 받아 설치하고, `scripts/common.sh`의 `BENCH` 스위치가 venv·suite·로그 디렉터리를 고른다. 러너 `agentdojo_ollama`는 세 포크가 공유하는 API만 쓰므로 그대로 동작하며, 집계기는 두 가지 로그 깊이를 모두 읽는다.

- **AgentDyn**: `scripts/run_agentdyn.sh`가 shopping/github/dailylife에 대해 E1 + E2를 돌린다. camel/drift/progent 등 추가 방어는 OpenAI/Google 클라이언트를 직접 요구해 1차 범위에서 제외.
- **AutoDojo 1단계(전이)**: `scripts/run_autodojo_transfer.sh`가 논문 캐시(`variants/<suite>/<SOURCE_MODEL>/<defense>/`)를 우리 모델에 주입해 정적 공격과 비교한다. 공격자 LLM 불필요.
- **AutoDojo 2단계(직접 최적화)**: `scripts/run_autodojo_optimize.sh`가 `optimize_variants.py`를 타깃 = Ollama 모델, 최적화 LLM = Ollama 모델(`OPTIMIZER_MODEL`, 기본 동일 태그)로 실행하고 생성된 캐시로 벤치마크한다. 이를 위해 `patches/autodojo-ollama.patch`로 (a) `vllm_parsed` 타깃의 base URL/모델 태그/reasoning_effort 환경변수화, (b) qwen 모델에도 reasoning_effort 전송, (c) 최적화 LLM 프로바이더 `ollama` 추가, (d) DRIFT 방어 모델 원격 지정을 넣었다.
- 검증: 모의 Ollama 서버로 AgentDyn 3 suite 실행, AutoDojo 캐시 공격·방어 실행, 최적화 1회 반복(타깃 160회 tool-calling 요청 + 최적화 LLM 8회 텍스트 요청, 모두 `reasoning_effort=none`/명시 temperature) → 캐시 생성 → 벤치마크까지 확인.
- 실행 비용 주의: 2단계는 (injection task × vector × iteration × screening user task) 만큼 타깃 호출이 발생한다. 27B 모델 단일 GPU에서는 `--max-injection-tasks`, `ITERATIONS`, `N_VARIANTS`를 줄여 먼저 시간을 잰다.

### 7.2 AgentDojo-Inspect

1. **AgentDojo-Inspect**: `pip install -e ".[inspect]"` 후 `scripts/run_inspect.sh` 실행 (`inspect eval inspect_evals/agentdojo --model openai-api/ollama/<tag>`). Inspect의 `openai-api` 프로바이더는 `OPENAI_BASE_URL`로 임의의 OpenAI 호환 서버를 가리킬 수 있어 같은 Ollama 서버를 재사용한다. `workspace_plus`의 sandbox 태스크는 Docker가 필요하므로 기본은 `with_sandbox_tasks=no`.
2. 원본 AgentDojo와 Inspect판의 태스크 차이(버그 수정, 추가 인젝션 태스크)를 결과에 분리 기록한다.
3. 여유가 되면 InjecAgent / ASB로 동일 모델을 평가해 벤치마크 간 ASR 경향을 비교한다.

---

## 8. 진행 상태

- [x] Phase 1 저장소 스캐폴딩 + 러너/집계기 구현, 모의 서버로 검증
- [ ] Phase 0 사내망에서 `scripts/check_ollama.sh` 실행 → 모델 태그·tool calling·num_ctx 확정
- [ ] Phase 2 `scripts/run_smoke.sh` 통과, 태스크당 소요 시간 기록
- [ ] Phase 3 E1 → E2 → E3 → E4 순으로 실행, 각 단계 결과를 `results/`에 커밋
- [ ] Phase 4 `scripts/summarize.sh`로 비교표, 공식 리더보드와 대조
- [x] Phase 5a AgentDyn / AutoDojo 통합 (setup 스크립트, 패치, 실행 스크립트, 모의 서버 검증)
- [ ] Phase 5b 사내망에서 AgentDyn 3 suite, AutoDojo 전이 → 직접 최적화 순으로 실행
- [ ] Phase 5c `scripts/run_inspect.sh`로 AgentDojo-Inspect 확장
