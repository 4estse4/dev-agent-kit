#!/usr/bin/env bash
# 킷을 설치한 Python 프로젝트에서, 킷이 설치한 파일이 게이트의 ruff 를 통과하는가.
#
# 이 테스트가 있는 이유: 킷이 설치하는 `.claude/hooks/round_comment_cmd.py` 가 킷이 함께 놓는 `ruff.toml` 의 포맷에
# 맞지 않았다(이슈 #205). 커밋 훅은 `gate.sh --lint --staged` 로 스테이지된 파일이 있는 모듈에 `ruff format --check .`
# 를 실행하므로, 루트가 Python 모듈인 레포에서는 설치 직후부터 커밋이 막혔다. 킷은 자기 파일에 게이트를 적용하지
# 않아(이슈 #4) 그것을 알리는 것이 없었다. 그 파일을 포맷한 뒤에도, 프로젝트가 pyproject 에 `[tool.ruff]` 를 두면
# 설치기가 킷의 `ruff.toml` 을 루트에 놓지 않아 설치된 파일이 프로젝트 설정으로 검사되고 같은 실패가 남았다(PR #207
# 1라운드 콜드 리뷰). 그래서 킷은 `.claude/` 에 자기 ruff 설정(`claude-code/ruff.toml`)을 둔다 — ruff 는 파일마다
# 가장 가까운 설정 파일을 쓴다.
#
# 원격 없는 새 Python 레포에 킷을 옵션 없이 설치하고, 그 레포에서 게이트를 실행한다. 게이트는 `.venv/bin/ruff` 를
# 먼저 쓰므로(`adapters/py.sh`) 거기에 PATH 의 ruff 를 둔다. 보는 것:
#   · PATH 의 ruff 가 `common/gate/tool-versions` 의 핀과 같다 — 다르면 판정하지 못한 것이라 실패한다. CI 는 핀 버전을
#     설치하고(`kit-tests.yml`), 로컬에서는 핀 버전을 PATH 앞에 두고 실행한다
#   · `claude-code/ruff.toml` 의 설정 줄(줄 전체가 주석인 줄과 빈 줄을 뺀 것)이 `common/lint/py/ruff.toml` 과 같다 —
#     설치된 킷 파일은 킷이 프로젝트 루트에 놓는 설정과 같은 설정으로 검사된다. 프로젝트의 `tests/` 를 가리키는
#     `[lint.per-file-ignores]` 표는 견주지 않는다 — `.claude/` 아래에는 그 자리가 없고, 설치된 파일이 킷에만 있는
#     경로를 가리키면 `tests/installed-docs.sh` 가 막는다
#   · pyproject 에 `[tool.ruff]` 가 없는 레포(킷의 `ruff.toml` 이 루트에 놓인다)와 있는 레포(놓이지 않는다) 모두에서
#     설치한 그대로 `gate.sh --lint` 가 `ruff format` · `ruff check` 를 둘 다 실행해 통과한다. 있는 레포의 설정은
#     `target-version` 한 줄이라 줄 길이와 규칙은 ruff 의 기본값이다
# `.claude/` 밖에 놓이는 킷 파일(`docs/process/` 등)은 프로젝트 루트의 설정으로 검사된다. 이 테스트는 그 설정이 킷의
# `ruff.toml` 일 때와 ruff 의 기본값일 때만 본다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

pin=$(sed -n 's/^ruff=//p' "$KIT/common/gate/tool-versions")
got=$(ruff --version 2>/dev/null | awk '{print $2}')
if [ -z "$pin" ] || [ "$got" != "$pin" ]; then
  echo "  ✗ PATH 의 ruff 가 핀 버전이 아니다(핀 ${pin:-없음} · PATH ${got:-없음}) — 판정하지 못했다."
  echo "    핀 버전을 받아 PATH 앞에 두고 다시 실행한다. 버전은 common/gate/tool-versions 의 ruff 다."
  exit 1
fi

settings() { # $1=ruff 설정 파일 → [lint.per-file-ignores] 표와 주석 줄 · 빈 줄을 뺀 줄
  awk '/^\[/ { skip = ($0 == "[lint.per-file-ignores]") } !skip' "$1" | grep -v -E '^[[:space:]]*(#|$)'
}
if [ -f "$KIT/claude-code/ruff.toml" ] \
   && cmp -s <(settings "$KIT/claude-code/ruff.toml") <(settings "$KIT/common/lint/py/ruff.toml"); then
  echo "  ✓ claude-code/ruff.toml 의 설정 줄이 common/lint/py/ruff.toml 과 같다"
else
  echo "  ✗ claude-code/ruff.toml 이 없거나 설정 줄이 common/lint/py/ruff.toml 과 다르다"
  fail=1
fi

T=$(mktemp -d)
demo() { # $1=이름 $2=pyproject.toml 내용 $3=루트에 킷의 ruff.toml 이 놓여야 하나(놓임|안 놓임)
  local R="$T/$1" out rc root
  mkdir -p "$R"; git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  printf 'def hello():\n    return "hi"\n' > "$R/app.py"
  printf '%s' "$2" > "$R/pyproject.toml"
  git -C "$R" add -A && git -C "$R" commit -q -m init
  if ! bash "$KIT/install.sh" "$R" > "$T/$1-install.log" 2>&1; then
    echo "  ✗ $1: 설치가 실패했다"; tail -5 "$T/$1-install.log" | sed 's/^/      /'; fail=1; return
  fi
  [ -f "$R/ruff.toml" ] && root=놓임 || root="안 놓임"
  if [ "$root" != "$3" ]; then
    echo "  ✗ $1: 루트에 킷의 ruff.toml 이 $root — $3 이어야 이 경우를 본다"; fail=1; return
  fi
  mkdir -p "$R/.venv/bin" && ln -s "$(command -v ruff)" "$R/.venv/bin/ruff"
  out=$(cd "$R" && bash .kit/gate/gate.sh --lint 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^gate ✓.*ruff format.*ruff check'; then
    echo "  ✓ $1(루트의 ruff.toml $root): 게이트의 ruff format · ruff check 가 통과한다(ruff $pin)"
  else
    echo "  ✗ $1(루트의 ruff.toml $root): 게이트가 ruff 를 통과하지 못했다(rc=$rc, ruff $pin):"
    printf '%s\n' "$out" | grep -E '^gate |^──── |^ *--> |would be reformatted|^[A-Z]+[0-9]+ ' | sed 's/^/      /'
    fail=1
  fi
}
demo kit-config $'[project]\nname = "demo"\nversion = "0.1.0"\n' 놓임
demo project-config $'[project]\nname = "demo"\nversion = "0.1.0"\n\n[tool.ruff]\ntarget-version = "py312"\n' "안 놓임"

rm -rf "$T"
exit $fail
