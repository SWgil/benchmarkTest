"""적응형(adaptive) 공격 최적화기: AgentVigil(MCTS 퍼징), IterInject(피드백 기반 반복 최적화).

두 논문 모두 공식 코드가 공개되지 않아 논문 설명을 따라 재구현했다. 공통 전제:
- 타깃은 블랙박스 Ollama 모델(방어 없음 기본). 성공 여부(security)와 메시지 트레이스만 관측한다.
- 공격자/보조 LLM도 Ollama 모델이다 (AutoDojo 통합과 같은 구성).
- 결과 캐시(JSON)를 만든 뒤 `agentdojo-ollama --attack agentvigil|iterinject` 로 벤치마크한다.
"""
