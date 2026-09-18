# benchmarkTest — AgentDojo 계열 벤치마크 × Ollama(qwen3.8:27b)

로컬 Ollama 서버(`10.25.36.222:9090`)의 모델로 [AgentDojo](https://github.com/ethz-spylab/agentdojo) 프롬프트 인젝션 벤치마크를 실행하고 집계하는 환경입니다. 전체 계획은 [PLAN.md](PLAN.md)를 보세요.

## 왜 자체 러너인가

- PyPI `agentdojo==0.1.35`에는 OpenAI 호환 서버용 프로바이더가 없습니다 (main 브랜치에만 있음).
- 원본 `OpenAILLM`은 `temperature=0.0`을 실제로 전송하지 않습니다.
- Qwen3 계열의 thinking 출력을 끄고(`reasoning_effort=none`, `/no_think`) `<think>` 블록을 제거해야 합니다.

그래서 `agentdojo_ollama/` 패키지가 `OpenAILLM`을 상속한 `OllamaLLM`과 원본 CLI와 동일한 옵션의 러너를 제공합니다. 로그 형식과 디렉터리 구조는 원본과 같으므로 원본 분석 도구(`agentdojo.benchmark.load_suite_results`)를 그대로 쓸 수 있습니다.

## 설치

```bash
uv venv && source .venv/bin/activate      # 또는 python3 -m venv .venv
uv pip install -e .                       # agentdojo 0.1.35 + 러너
# 선택
uv pip install -e ".[transformers]"       # transformers_pi_detector 방어
uv pip install -e ".[inspect]"            # Phase 5: AgentDojo-Inspect
cp .env.example .env                      # 서버/모델 설정 (configs/qwen3.8-27b.env 가 기본값)
```

## 실행 순서

```bash
scripts/check_ollama.sh          # Phase 0: 태그·tool calling·num_ctx 점검
scripts/run_smoke.sh             # Phase 2: 태스크 몇 개로 파이프라인 확인
MAX_WORKERS=4 scripts/run_utility.sh   # E1: 유틸리티 (97 tasks)
MAX_WORKERS=4 scripts/run_attack.sh    # E2: important_instructions (629 cases)
ATTACK=tool_knowledge scripts/run_attack.sh            # E3: 공격 변형
DEFENSES="tool_filter repeat_user_prompt" scripts/run_defense.sh   # E4: 방어
scripts/summarize.sh             # Phase 4: results/<model>_<date>.md / .csv
scripts/run_inspect.sh           # Phase 5: AgentDojo-Inspect
```

완료된 태스크는 건너뛰므로 중단 후 재실행이 가능합니다. 다시 돌리려면 `-f`를 넘기세요.

직접 실행할 때:

```bash
agentdojo-ollama --model qwen3.8:27b --base-url http://10.25.36.222:9090/v1 \
  -s workspace -ut user_task_0 -it injection_task_0 --attack important_instructions
agentdojo-ollama --help
```

thinking을 켠 상태로 비교 실험을 하려면:

```bash
EXTRA_ARGS="--reasoning-effort '' --no-no-think-tag --logdir runs_think" scripts/run_utility.sh
```

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
agentdojo_ollama/   러너(run.py), OllamaLLM(llm.py), 집계(summarize.py)
scripts/            Phase별 실행 스크립트 (common.sh 가 configs/ 와 .env 를 로드)
configs/            모델별 env, Ollama Modelfile
runs/               벤치마크 로그 (gitignore)
results/            집계 결과 (커밋 대상)
```
