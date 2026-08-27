#!/usr/bin/env bash
# 한 파이썬 패키지 디렉터리에 **개발 의존성**을 설치한다. $1=디렉터리(기본 .)
#
# 왜 스크립트로 빼나 — CI 의 gate 잡과 coverage 잡이 둘 다 이것을 필요로 한다.
# 워크플로에 두 벌로 두면 반드시 어긋나고, 실제로 어긋났다: coverage 잡이
# `pip install -e .` 만 해서 pytest-cov 를 못 깔고는 "프로젝트가 선언하지
# 않았다" 고 잘못 알렸다.
#
# $GITHUB_PATH 에 venv 를 얹지 않는다. 그것은 잡 전체에 prepend 되므로 패키지가
# 여럿이면 **어느 하나의 venv 가 전부를 이긴다** — 남의 의존성으로 테스트가 돈다.
# 대신 어댑터가 자기 디렉터리의 .venv/bin 을 먼저 본다(adapters/py.sh).
set -euo pipefail
cd "${1:-.}"

# macOS 에는 `python` 이 없고 `python3` 만 있다. 없는 채로 흘려보내면 _has() 가
# 127 을 반환하고 그것이 elif 조건이라 다음 분기로 새서, **선언이 있는데도**
# "dev 의존성 선언이 없습니다" 로 끝난다. 이 스크립트가 없애려던 그 거짓 안내다.
PY=$(command -v python3 || command -v python) || {
  echo "install-dev-deps: python3 이 없습니다 — 검사할 수 없습니다" >&2; exit 1; }
[ -f pyproject.toml ] || { echo "install-dev-deps: pyproject.toml 이 없습니다 — $(pwd)" >&2; exit 1; }

# venv 를 만들면 **활성화까지 한다.** 만들기만 하면 이어지는 pip 는 바깥
# 인터프리터에 깔고 .venv 는 빈 채 남는데, coverage 잡은 그 빈 venv 를 켜고
# "pytest-cov 가 없다" 는 거짓 안내를 낸다(재현함).
# uv·poetry 분기는 자기가 venv 를 만들고 채우므로 이 함수를 쓰지 않는다.
_venv() {
  "$PY" -m venv .venv
  # shellcheck source=/dev/null
  . .venv/bin/activate
  python -m pip install -q --upgrade pip >/dev/null 2>&1 || true
}

_has() { # $1=tomllib 로 확인할 파이썬 식
  "$PY" - "$1" <<'PYCHK'
import sys, tomllib, pathlib
d = tomllib.loads(pathlib.Path("pyproject.toml").read_text())
sys.exit(0 if eval(sys.argv[1], {"d": d}) else 1)
PYCHK
}

if [ -f uv.lock ]; then
  pipx install "uv==${AI_KIT_UV_VERSION:-0.9.7}" >/dev/null 2>&1 || pipx install uv >/dev/null 2>&1 || true
  # --locked: 락과 pyproject 가 어긋나면 조용히 갱신하지 말고 실패한다.
  # 커밋된 락과 다른 해상도로 CI 가 통과하면 그 차이는 아무도 못 본다.
  uv sync --locked --all-extras --all-groups   # extras 로 dev 를 선언한 레포도 덮는다
elif [ -f poetry.lock ]; then
  pipx install "poetry==${AI_KIT_POETRY_VERSION:-2.2.1}" >/dev/null 2>&1 || pipx install poetry >/dev/null 2>&1 || true
  # in-project venv 로 강제해 어댑터가 .venv/bin 에서 찾게 한다.
  poetry config virtualenvs.in-project true --local
  # 그룹 이름을 추측하지 않는다 — `--with dev` 는 dev 그룹이 없으면 exit 1 이다.
  # --no-root 도 쓰지 않는다: 형제 분기가 루트를 설치하므로 여기만 빼면
  # 테스트가 자기 패키지를 import 하지 못한다.
  if poetry check --quiet 2>/dev/null && \
     _has "'dev' in (((d.get('tool') or {}).get('poetry') or {}).get('group') or {})"; then
    poetry install --with dev
  else
    poetry install
  fi
elif _has "'dev' in (d.get('dependency-groups') or {})"; then
  _venv; python -m pip install --group dev -e .
elif _has "'dev' in ((d.get('project') or {}).get('optional-dependencies') or {})"; then
  _venv; python -m pip install -e '.[dev]'
elif [ -f requirements-dev.txt ]; then
  _venv; python -m pip install -r requirements-dev.txt
else
  echo "::notice::$(pwd) 에 dev 의존성 선언이 없습니다 — pytest·mypy 를 쓴다면" \
       "uv.lock · poetry.lock · [dependency-groups].dev ·" \
       "[project.optional-dependencies].dev · requirements-dev.txt 중 하나로 선언하세요."
fi
