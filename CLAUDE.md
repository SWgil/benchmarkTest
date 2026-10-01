# CLAUDE.md — 프로젝트 메모

이 저장소(benchmarkTest)는 로컬 Ollama 모델(`qwen3.8:27b`)로 AgentDojo 계열
프롬프트 인젝션 벤치마크를 돌려 **방어 없는 상태의 LLM 자체 IPI 저항성**을 측정한다.
전체 설명은 [README.md](README.md), 계획은 [PLAN.md](PLAN.md) 참고.

## 작업 기록 / 브랜치

- **`feat/piarena-nonagent-eval`** (2026-10-01): PIArena(sleeepeer/PIArena, ACL 2026)의
  **비-에이전트 정적 데이터셋 평가**(QA/RAG/요약/롱컨텍스트, 1,700 샘플)를 원격 Ollama에
  돌리는 트랙을 추가한 브랜치. 자동 생성 브랜치 `ccr-e64d5320-58t2q5`에서 이 이름으로 변경했다.
  (이전 자동 브랜치는 이 환경의 프록시 제약으로 원격에서 삭제하지 못해 남아 있을 수 있음 →
  GitHub UI에서 삭제 가능.)
  - 범위: **AgentDojo/AgentDyn 에이전트 벤치마크는 제외**(기존 `BENCH=agentdojo`/`agentdyn`
    트랙과 겹침). **적응형 공격**(strategy_search/pair/tap/nanogcg)은 정적 평가 결과를 본 뒤
    도입을 결정하기로 하여 보류.
  - 구성: `scripts/setup_piarena.sh`, `scripts/run_piarena.sh`, `patches/piarena-ollama.patch`
    (OpenAIModel base_url/thinking 처리, GPU 강제 완화, judge 원격화, 방어 lazy-import).
  - 아직 main 에 병합되지 않았다. 실제 수치는 사내망(Ollama `10.251.36.222`)에서 실행해야 함.
