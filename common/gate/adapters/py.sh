#!/usr/bin/env bash
# Python 게이트. CWD = pyproject.toml 이 있는 디렉터리. lib.sh 는 이미 source 됨.
#
# 도구는 **프로젝트가 선언한 것**을 먼저 쓴다. 린트 규칙을 정하는 것이 프로젝트이므로
# 버전도 프로젝트가 정하는 것이 맞다. 아무것도 선언하지 않았으면 PATH 의 것으로
# 폴백하고(CI 는 tool-versions 에 핀한 버전을 거기 설치해 둔다), 그것도 없으면 건너뛴다
# — GATE_STRICT 면 실패로 승격되고 그 사실을 말한다.

gate_have python3 || { gate_skip "python3(미설치)"; return 0 2>/dev/null || exit 0; }

# 도구는 **이 패키지의 venv 것**을 먼저 쓴다.
#
# PATH 에 있는 것을 그냥 부르면, 모노레포에서 어느 한 패키지의 venv 가 PATH 앞에
# 붙는 순간 **모든** 패키지의 테스트가 그 환경에서 돈다 — 남의 의존성으로 통과하거나
# 없는 의존성으로 실패한다. 어댑터는 패키지 디렉터리에서 도니 `.venv/bin` 이 바로 옆이다.
# (uv·poetry·python -m venv 가 모두 이 자리를 쓴다. poetry 는 in-project 설정일 때.)
_py() { # $1=도구 이름 → 실행할 경로를 echo, 없으면 실패
  local d
  for d in .venv venv; do
    [ -x "$d/bin/$1" ] && { printf '%s' "$d/bin/$1"; return 0; }
  done
  gate_have "$1" && { printf '%s' "$1"; return 0; }
  return 1
}

# ruff 는 포맷과 린트를 한 도구가 한다. 둘을 따로 보고해야 어느 쪽이 깨졌는지 보인다.
if _r=$(_py ruff); then
  gate_run "ruff format" "$_r" format --check .
  gate_run "ruff check"  "$_r" check .
  unset _r
else
  gate_skip "ruff"
fi

# mypy 는 설정이 있을 때만 돈다. 설정 없는 프로젝트에 걸면 서드파티 스텁 부재로
# 사실상 전부 실패하고, 그러면 게이트를 끄게 된다 — 끄는 게이트는 없는 게이트다.
_py_typed=""
grep -q '^\[tool\.mypy\]' pyproject.toml 2>/dev/null && _py_typed=1
[ -f mypy.ini ] || [ -f .mypy.ini ] && _py_typed=1
if [ -n "$_py_typed" ]; then
  if _m=$(_py mypy); then gate_run "mypy" "$_m" .; unset _m
  else gate_skip "mypy(설정은 있으나 미설치)"; fi
fi

# pytest 는 있으면 무조건 돈다. 테스트가 하나도 없으면 pytest 는 exit 5 를 내는데,
# 그것은 실패가 아니라 "수집할 것이 없음" 이다 — `go test ./...` 가 테스트 없는
# 패키지에서 통과하는 것과 같이 취급한다. Go 는 통과하고 Python 만 실패하면
# 언어에 따라 기준이 달라지고, 그런 게이트는 신뢰를 잃는다.
if [ "${GATE_LINT_ONLY:-0}" = 1 ]; then
  :
elif _p=$(_py pytest); then
  # shellcheck disable=SC2086
  out=$("$_p" -q ${AI_KIT_PYTEST_FLAGS:-} 2>&1); rc=$?
  case "$rc" in
    0) GATE_PASSED+=("pytest") ;;
    5) GATE_PASSED+=("pytest(테스트 없음)") ;;
    *) GATE_FAILED+=("pytest")
       GATE_FAILOUT+=$'\n'"──── pytest ────"$'\n'"$out"$'\n' ;;
  esac
  unset out rc _p
else
  gate_skip "pytest"
fi
unset _py_typed
