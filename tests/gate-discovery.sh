#!/usr/bin/env bash
# 설치되는 파일에서 모듈 마커를 찾는 find 는 게이트와 같은 기준을 쓴다.
#
# 이 테스트가 있는 이유: gate.sh 는 깊이를 제한하지 않고 lib.sh 의 GATE_PRUNE_ARGS 로
# node_modules 같은 것만 건너뛰는데, gates.yml 과 install-tools.sh 는 `-maxdepth 3` 과 제각각의
# `-not -path` 를 썼다. gate.sh 에서 깊이 제한을 뺄 때 나머지는 고치지 않아서, 네 단계 아래의 모듈을
# 로컬 게이트는 보고 CI 의 언어 감지와 도구 설치는 못 봤다(이슈 #37). 같은 기준을 두 곳에 적으면
# 한쪽만 고쳐진다. 새로 쓰는 자리를 찾아내는 것은 이 검사뿐이다.
#
# 보는 것: `.md` 가 아닌 설치되는 파일(common/ · claude-code/)과 install.sh 에서 주석이 아닌 줄.
#   · 마커를 찾는 find 는 GATE_PRUNE_ARGS 를 쓰고, -maxdepth 를 쓰지 않고, -not -path ·
#     ! -path 로 따로 거르지 않는다. prune 그룹 안에 이름을 더하는 모양은 보지 않는다 —
#     정규식으로 그 모양까지 좇으면 검사를 피하는 모양이 끝없이 새로 나온다
#   · 경로 목록을 `for x in $(find …)` · `$(dirname …)` 로 순회하지 않는다 — 공백 든 경로에서
#     낱말이 나뉜다(이슈 #80)
# 마커를 찾는 find 는 `-name` 뒤에 마커 이름이 글자로 오거나 변수(`-name "$1"`)가 오는 것이다.
# 변수 쪽을 빼면 기준이 되는 gate.sh 와 설치기의 탐색이 검사 밖에 남는다 — 첫 판이 그랬고,
# gate.sh 를 maxdepth 3 으로 되돌려도 이 테스트가 통과했다.
# `\` 로 이어진 줄은 붙여서 본다. find 가 여러 줄에 걸쳐 있다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1

files=$(git -c core.quotePath=false ls-files common claude-code install.sh | grep -v -E '\.md$|settings\.json$')
[ -n "$files" ] || { echo "  ✗ 검사할 파일이 없다 — 경로가 바뀌었나"; exit 1; }

# 파일마다 `\` 로 이어진 줄을 붙이고, 주석이 아닌 논리 줄을 `파일:시작행:내용` 으로 낸다.
logical() {
  local f
  while IFS= read -r f; do
    awk -v f="$f" '
      { line = $0 }
      cont { buf = buf " " line } !cont { buf = line; start = NR }
      /\\$/ { sub(/\\$/, "", buf); cont = 1; next }
      { cont = 0; if (buf !~ /^[[:space:]]*#/) print f ":" start ":" buf }
    ' "$f"
  done <<< "$files"
}

MARKER="-name[[:space:]]+(['\"]?(go\\.mod|package(-lock)?\\.json|pyproject\\.toml|settings\\.gradle(\\.kts)?|build\\.gradle(\\.kts)?)|\"?\\$)"
finds=$(logical | grep -E "find[[:space:]].*$MARKER")
[ -n "$finds" ] || { echo "  ✗ 마커를 찾는 find 를 하나도 찾지 못했다 — 정규식이 틀렸나"; exit 1; }

fail=0
bad=$(printf '%s\n' "$finds" | grep -vF '"${GATE_PRUNE_ARGS[@]}"')
if [ -n "$bad" ]; then
  echo "  ✗ 마커를 찾는 find 가 \"\${GATE_PRUNE_ARGS[@]}\" 를 안 쓴다:"
  printf '%s\n' "$bad" | cut -c1-160 | sed 's/^/      /'
  fail=1
fi
bad=$(printf '%s\n' "$finds" | grep -e '-maxdepth')
if [ -n "$bad" ]; then
  echo "  ✗ 마커를 찾는 find 에 -maxdepth 가 있다:"
  printf '%s\n' "$bad" | cut -c1-160 | sed 's/^/      /'
  fail=1
fi
bad=$(printf '%s\n' "$finds" | grep -E '(-not|!)[[:space:]]+-path')
if [ -n "$bad" ]; then
  echo "  ✗ 마커를 찾는 find 가 -not -path 로 따로 거른다:"
  printf '%s\n' "$bad" | cut -c1-160 | sed 's/^/      /'
  fail=1
fi
bad=$(logical | grep -E 'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+\$\((dirname|find)[[:space:]]')
if [ -n "$bad" ]; then
  echo "  ✗ 경로 목록을 for … in \$(find|dirname …) 로 순회한다:"
  printf '%s\n' "$bad" | cut -c1-160 | sed 's/^/      /'
  fail=1
fi

if [ "$fail" = 0 ]; then
  n=$(printf '%s\n' "$finds" | wc -l | tr -d ' ')
  echo "  ✓ 마커를 찾는 find ${n}개(이름을 변수로 받는 것 포함)가 전부 GATE_PRUNE_ARGS 를 쓰고 -maxdepth · -not -path 가 없다 · for \$(find) 루프 없음"
fi
exit $fail
