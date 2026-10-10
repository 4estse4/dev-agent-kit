#!/usr/bin/env bash
# 킷을 설치한 Python 프로젝트에서, 킷이 설치한 파일이 게이트의 ruff 를 통과하는가.
#
# 이 테스트가 있는 이유: 킷이 설치하는 `.claude/hooks/round_comment_cmd.py` 가 킷이 함께 놓는 `ruff.toml` 의 포맷에
# 맞지 않았다(이슈 #205). 커밋 훅은 `gate.sh --lint --staged` 로 스테이지된 파일이 있는 모듈에 `ruff format --check .`
# 를 실행하므로, 루트가 Python 모듈인 레포에서는 설치 직후부터 커밋이 막혔다. 킷은 자기 파일에 게이트를 적용하지
# 않아(이슈 #4) 그것을 알리는 것이 없었다.
#
# 원격 없는 새 Python 레포에 킷을 옵션 없이 설치하고, 그 레포에서 게이트를 실행한다. 게이트는 `.venv/bin/ruff` 를
# 먼저 쓰므로(`adapters/py.sh`) 거기에 PATH 의 ruff 를 둔다. 보는 것:
#   · PATH 의 ruff 가 `common/gate/tool-versions` 의 핀과 같다 — 다르면 판정하지 못한 것이라 실패한다. CI 는 핀 버전을
#     설치하고(`kit-tests.yml`), 로컬에서는 핀 버전을 PATH 앞에 두고 실행한다
#   · 설치한 그대로 `gate.sh --lint` 가 `ruff format` · `ruff check` 를 둘 다 실행해 통과한다
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

T=$(mktemp -d)
R="$T/demo"; mkdir -p "$R"; git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
printf 'def hello():\n    return "hi"\n' > "$R/app.py"
printf '[project]\nname = "demo"\nversion = "0.1.0"\n' > "$R/pyproject.toml"
git -C "$R" add -A && git -C "$R" commit -q -m init

if ! bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1; then
  echo "  ✗ 설치가 실패했다"; tail -5 "$T/install.log" | sed 's/^/      /'
  rm -rf "$T"; exit 1
fi
mkdir -p "$R/.venv/bin" && ln -s "$(command -v ruff)" "$R/.venv/bin/ruff"

out=$(cd "$R" && bash .kit/gate/gate.sh --lint 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^gate ✓.*ruff format.*ruff check'; then
  echo "  ✓ 킷을 설치한 Python 레포에서 게이트의 ruff format · ruff check 가 통과한다(ruff $pin)"
else
  echo "  ✗ 킷을 설치한 Python 레포에서 게이트가 ruff 를 통과하지 못했다(rc=$rc, ruff $pin):"
  printf '%s\n' "$out" | grep -E '^gate |^──── |^ *--> |would be reformatted|^[A-Z]+[0-9]+ ' | sed 's/^/      /'
  fail=1
fi

rm -rf "$T"
exit $fail
