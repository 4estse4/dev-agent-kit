#!/usr/bin/env bash
# Python 게이트. CWD = pyproject.toml 이 있는 디렉터리. lib.sh 는 이미 source 됨.
#
# 도구는 프로젝트 환경의 것을 쓴다 — 킷이 자기 버전을 끌어오면 로컬과 CI 가 다른
# 규칙으로 검사하게 된다. 없으면 건너뛰고(GATE_STRICT 면 실패로 승격) 그 사실을 말한다.

gate_have python3 || { gate_skip "python3(미설치)"; return 0 2>/dev/null || exit 0; }

# ruff 는 포맷과 린트를 한 도구가 한다. 둘을 따로 보고해야 어느 쪽이 깨졌는지 보인다.
if gate_have ruff; then
  gate_run "ruff format" ruff format --check .
  gate_run "ruff check"  ruff check .
else
  gate_skip "ruff"
fi

# mypy 는 설정이 있을 때만 돈다. 설정 없는 프로젝트에 걸면 서드파티 스텁 부재로
# 사실상 전부 실패하고, 그러면 게이트를 끄게 된다 — 끄는 게이트는 없는 게이트다.
_py_typed=""
grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null && _py_typed=1
[ -f mypy.ini ] || [ -f .mypy.ini ] && _py_typed=1
if [ -n "$_py_typed" ]; then
  gate_have mypy && gate_run "mypy" mypy . || gate_skip "mypy(설정은 있으나 미설치)"
fi

# pytest 도 테스트가 실재할 때만. 테스트 없는 디렉터리에서 pytest 는 exit 5 를 내는데
# 그것을 실패로 보고하면 "테스트를 아직 안 썼다" 가 게이트 실패가 된다.
if gate_have pytest && { [ -d tests ] || [ -d test ] || ls -1 test_*.py *_test.py >/dev/null 2>&1; }; then
  # shellcheck disable=SC2086
  gate_run "pytest" pytest -q ${AI_KIT_PYTEST_FLAGS:-}
elif gate_have pytest; then
  gate_skip "pytest(테스트 없음)"
else
  gate_skip "pytest"
fi
unset _py_typed
