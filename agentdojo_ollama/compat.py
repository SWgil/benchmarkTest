"""설치된 `agentdojo` 패키지가 어느 포크인지 감지한다.

세 포크(원본 AgentDojo, AgentDyn, AutoDojo)는 모두 `agentdojo`라는 같은 이름으로 설치되므로
venv 하나에 하나만 존재한다. 러너는 공통 API만 쓰지만, 로그 경로 형식과 suite 목록이 달라
집계·안내 메시지에 포크 이름이 필요하다.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


def detect_bench() -> str:
    """'agentdojo' | 'agentdyn' | 'autodojo'"""
    if importlib.util.find_spec("agentdojo.attacks.autodojo_attack") is not None:
        return "autodojo"
    if importlib.util.find_spec("agentdojo.default_suites.v1.shopping") is not None:
        return "agentdyn"
    return "agentdojo"


def agentdojo_root() -> Path:
    import agentdojo

    return Path(agentdojo.__file__).resolve().parent
