# benchmarkTest — AgentDojo 계열 벤치마크 × Ollama(qwen3.8:27b)

로컬 Ollama 서버(`10.251.36.222:9090`)의 모델로 [AgentDojo](https://github.com/ethz-spylab/agentdojo) 계열 프롬프트 인젝션 벤치마크를 실행하고 집계하는 환경입니다. 전체 계획은 [PLAN.md](PLAN.md)를 보세요.

**측정 대상은 방어 기법이 없는 상태에서의 LLM 자체 IPI(간접 프롬프트 인젝션) 저항성**입니다. 모든 스크립트의 기본값은 방어 없음이며, 방어 기법 실험은 선택 사항(`run_defense.sh`, `DEFENSES=`)입니다.

| BENCH | 벤치마크 | 내용 | 설치 |
|---|---|---|---|
| `agentdojo` | [AgentDojo](https://github.com/ethz-spylab/agentdojo) 0.1.35 / v1.2.2 | workspace, slack, travel, banking (97 tasks, 629 cases) | `pip install -e .` |
| `agentdyn` | [AgentDyn](https://github.com/SaFo-Lab/AgentDyn) | + shopping, github, dailylife (60 open-ended tasks, 560 cases) | `scripts/setup_agentdyn.sh` |
| `autodojo` | [AutoDojo](https://github.com/xhOwenMa/AutoDojo) | 적응형 공격: 우리 모델(방어 없음)을 타깃으로 인젝션을 직접 최적화한 뒤 벤치마크 | `scripts/setup_autodojo.sh` |

세 벤치마크는 모두 `agentdojo`라는 같은 패키지 이름의 포크라서 **venv를 따로** 씁니다(`.venv-agentdojo`, `.venv-agentdyn`, `.venv-autodojo`). `scripts/common.sh`가 `BENCH` 값에 따라 venv, 기본 suite, 로그 디렉터리(`runs/<BENCH>/`)를 고릅니다.

## 왜 자체 러너인가

- PyPI `agentdojo==0.1.35`에는 OpenAI 호환 서버용 프로바이더가 없습니다 (main 브랜치에만 있음).
- 원본 `OpenAILLM`은 `temperature=0.0`을 실제로 전송하지 않습니다.
- Qwen3 계열의 thinking 출력을 끄고(`reasoning_effort=none`, `/no_think`) `<think>` 블록을 제거해야 합니다.

그래서 `agentdojo_ollama/` 패키지가 `OpenAILLM`을 상속한 `OllamaLLM`과 원본 CLI와 동일한 옵션의 러너를 제공합니다. 로그 형식과 디렉터리 구조는 원본과 같으므로 원본 분석 도구(`agentdojo.benchmark.load_suite_results`)를 그대로 쓸 수 있습니다.

## 설치

```bash
# 1) 원본 AgentDojo
python3 -m venv .venv-agentdojo && .venv-agentdojo/bin/pip install -e .
# 선택: .venv-agentdojo/bin/pip install -e ".[transformers]"  (transformers_pi_detector 방어)
#       .venv-agentdojo/bin/pip install -e ".[inspect]"       (Phase 5: AgentDojo-Inspect)
# 2) AgentDyn (third_party/AgentDyn 를 sparse clone, runs/ 제외)
scripts/setup_agentdyn.sh
# 3) AutoDojo (third_party/AutoDojo clone + patches/autodojo-ollama.patch 적용)
scripts/setup_autodojo.sh
cp .env.example .env                      # 서버/모델 설정 (configs/qwen3.8-27b.env 가 기본값)
```

## 실행 순서

```bash
scripts/check_ollama.sh          # Phase 0: 태그·tool calling·num_ctx 점검
scripts/run_smoke.sh             # Phase 2: 태스크 몇 개로 파이프라인 확인
MAX_WORKERS=4 scripts/run_utility.sh   # E1: 유틸리티 (97 tasks)
MAX_WORKERS=4 scripts/run_attack.sh    # E2: important_instructions (629 cases)
ATTACK=tool_knowledge scripts/run_attack.sh            # E3: 공격 변형
# (선택, 범위 밖) DEFENSES="tool_filter repeat_user_prompt" scripts/run_defense.sh
scripts/summarize.sh             # Phase 4: results/<bench>_<model>_<date>.md / .csv
scripts/run_inspect.sh           # Phase 5: AgentDojo-Inspect

# AgentDyn (BENCH=agentdyn 를 붙이면 위 스크립트 전부 AgentDyn venv/suite 로 동작)
BENCH=agentdyn scripts/run_smoke.sh
MAX_WORKERS=3 scripts/run_agentdyn.sh              # shopping/github/dailylife: E1 + E2
BENCH=agentdyn scripts/summarize.sh

# AutoDojo
BENCH=autodojo scripts/run_smoke.sh                                         # 연결 확인용 (정적 공격)
SUITES=banking ITERATIONS=8 N_VARIANTS=5 scripts/run_autodojo_optimize.sh   # 방어 없는 타깃 직접 최적화 + 벤치마크
BENCH=autodojo scripts/summarize.sh
```

`SUITES="banking slack"`처럼 suite 목록을 덮어쓸 수 있습니다. 스크립트 뒤에 붙인 인자는 러너로 전달됩니다(예: `-ut user_task_0`).

완료된 태스크는 건너뛰므로 중단 후 재실행이 가능합니다. 다시 돌리려면 `-f`를 넘기세요.

직접 실행할 때:

```bash
agentdojo-ollama --model qwen3.8:27b --base-url http://10.251.36.222:9090/v1 \
  -s workspace -ut user_task_0 -it injection_task_0 --attack important_instructions
agentdojo-ollama --help
```

thinking을 켠 상태로 비교 실험을 하려면:

```bash
EXTRA_ARGS="--reasoning-effort '' --no-no-think-tag --logdir runs_think" scripts/run_utility.sh
```

## AutoDojo 사용법

AutoDojo 논문의 주제는 "방어를 상대로 한 적응형 공격"이라 포크에 방어 9종이 들어 있지만, 이 저장소는 **방어 없는 타깃에 대한 직접 최적화만** 수행합니다. 목적은 정적 `important_instructions` 대신 우리 모델에 맞춰 최적화된 인젝션을 썼을 때 ASR이 얼마나 오르는지, 즉 LLM 자체 저항성의 상한을 보는 것입니다. 논문에 커밋된 다른 모델용 캐시의 전이 평가는 하지 않습니다(다른 모델에 맞춰진 문구이고, banking 등은 상당수 셀이 정적 공격과 동일해 의미가 적음).

`run_autodojo_optimize.sh`는 suite마다 두 단계를 이어서 실행합니다.

1. `optimize_variants.py`로 우리 모델을 타깃 삼아 인젝션을 반복 최적화합니다. **타깃과 최적화(analyzer + rewriter) LLM 모두 Ollama 모델**을 씁니다. 최적화 LLM은 `OPTIMIZER_MODEL`로 바꿀 수 있고(기본은 타깃과 같은 태그), `OLLAMA_REASONING_EFFORT`를 비워 두면 thinking이 켜진 채로 문구를 생성합니다. 결과 캐시는 `runs/autodojo/variants/<suite>/<model>/no_defense/injections.json`.
2. 만들어진 캐시로 `--attack autodojo` 벤치마크를 돌립니다. 로그는 `runs/autodojo/<model>/no_defense/<suite>/…`.

주요 변수: `SUITES`(기본 banking slack travel; github/shopping/dailylife도 가능), `ITERATIONS`(기본 8), `N_VARIANTS`(기본 5), `OPT_EXTRA`(예: `--max-injection-tasks 2 --parallel-eval --eval-concurrency 4`). 비용은 injection task × vector × 반복 × screening user task만큼 타깃 호출이 발생하므로 작게 시작해 시간을 재세요. 방어 실험이 필요해지면 `DEFENSE=spotlighting`으로 켤 수 있습니다.

`patches/autodojo-ollama.patch`가 포크에 추가하는 것:

- `vllm_parsed` 타깃이 `LOCAL_LLM_BASE_URL`, `LOCAL_LLM_MODEL_ID`, `LOCAL_LLM_REASONING_EFFORT`를 읽어 원격 Ollama와 특정 모델 태그를 쓰도록 (원본은 localhost 고정 + `/v1/models` 첫 모델 자동 선택)
- qwen 계열 모델에도 `reasoning_effort`를 보내도록 (원본은 OpenRouter 제약 때문에 항상 생략)
- 최적화 LLM 프로바이더 `ollama` 추가 (`OLLAMA_BASE_URL`, `OLLAMA_API_KEY`, `OLLAMA_REASONING_EFFORT`)
- DRIFT 방어 모델도 같은 환경변수로 원격 지정 가능

참고로 AutoDojo의 필터 방어(`promptguard`, `piguard`, `protectai`, `datafilter`)는 GPU와 Hugging Face 토큰이 필요하고, `drift`/`progent`/`camel`은 추가 의존성이 필요합니다.

## 겹치는 suite 처리

banking, slack, travel, workspace는 세 벤치마크에서 태스크 코드와 데이터가 동일합니다(diff로 확인). 그래서:

- `BENCH=agentdyn` 기본 suite는 AgentDyn 고유의 shopping, github, dailylife뿐입니다. 원본 4개는 `SUITES=`로 명시할 때만 돕니다.
- `BENCH=autodojo`는 태스크가 아니라 공격(우리 모델에 맞춰 최적화된 인젝션)을 새로 측정합니다. 기준선(공격 없음, 정적 공격)은 다시 돌리지 않고 `results/agentdojo_*`의 E1/E2 행을 함께 놓고 비교합니다. AgentDyn 고유 suite에서 최적화하려면 `SUITES="shopping github dailylife"`로 지정합니다.

## 결과 해석

| 열 | 의미 |
|---|---|
| utility (attack=none) | 공격 없이 유저 태스크를 완수한 비율 |
| utility (attack=X) | 공격 하에서 유저 태스크를 완수한 비율 (utility under attack) |
| targeted ASR | 인젝션 태스크의 목표가 달성된 비율 (`security=True` 비율) |
| inj. tasks solvable | 인젝션 태스크를 유저 태스크로 직접 주었을 때 푼 개수 (모델이 아예 못 푸는 목표는 ASR 해석 시 제외 고려) |

공식 리더보드: https://agentdojo.spylab.ai/results/

## 레이아웃

```
agentdojo_ollama/   러너(run.py), OllamaLLM(llm.py), 포크 감지(compat.py), 집계(summarize.py)
scripts/            Phase별 실행 스크립트 (common.sh 가 BENCH/configs/.env 를 처리)
configs/            모델별 env, Ollama Modelfile
patches/            AutoDojo 포크용 Ollama 패치
third_party/        AgentDyn, AutoDojo 체크아웃 (gitignore; setup 스크립트가 핀 커밋으로 받음)
runs/<bench>/       벤치마크 로그 (gitignore)
results/            집계 결과 (커밋 대상)
```

러너는 세 포크가 공유하는 API(`PipelineConfig(llm=<element>)`, `benchmark_suite_*`, `load_attack`)만 사용하므로 포크별 코드 분기가 없습니다. 로그 경로는 원본/AgentDyn이 `<model>[-<defense>]/<suite>/…`, AutoDojo가 `<model>/<defense>/<suite>/…`이고 집계기는 둘 다 읽습니다.
