#!/usr/bin/env bash
# 세션(Claude Code 가 띄운 프로세스)이 붙인 우회 변수를 git 훅과 게이트가 받지 않는가.
#
# 이 테스트가 있는 이유: 우회 변수(`KIT_ALLOW_PROTECTED` · `KIT_ALLOW_MISSING_TOOLS`)는 사람이 의도적 예외를 둘 때
# 쓴다. 세션도 같은 변수를 명령 앞에 붙일 수 있었고, 어느 권한 규칙도 그것을 묻지 않았다(이슈 #46). 권한 규칙은 세션이
# 쓴 명령 글자에만 맞춰 보므로, 세션이 `export` 나 스크립트 파일로 값을 두면 규칙이 그 값을 보지 못한다. 그래서 훅과
# 게이트가 직접 본다 — Claude Code 는 자기가 띄운 프로세스에 `CLAUDE_CODE_CHILD_SESSION=1` 을 두고, 훅과 게이트는
# 세션이 실행한 git · bash 의 자식이라 그 값을 물려받는다.
# 보는 것:
#   · 세션이면 보호 브랜치 커밋을 `KIT_ALLOW_PROTECTED=1` 로 허용하지 않고, 사람(표시 없음)이면 허용한다
#   · 세션이면 `KIT_PROTECTED_BRANCHES` 가 기본값(main · master)을 빼지 못하고, 더한 브랜치는 보호한다. 사람이면 바꾼 값을 따른다
#   · 세션이 보호 브랜치가 아닌 곳에서 하는 커밋은 훅을 통과한다
#   · 세션이면 게이트가 `KIT_ALLOW_MISSING_TOOLS=1` 이나 `GATE_STRICT=0` 으로 어댑터 · 도구가 없는 검사를 건너뛰지 않는다.
#     사람이면 건너뛴다
#   · 거부할 때 원인 변수(`CLAUDE_CODE_CHILD_SESSION=1`)와, 세션 밖 터미널에서 사람이 하라는 것을 적는다
#
# 이 테스트를 세션이 실행해도 경우마다 표시를 직접 켜고 끈다(`env CLAUDE_CODE_CHILD_SESSION=1` · `env -u`).
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/common/git-hooks/pre-commit"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
SESSION=(env CLAUDE_CODE_CHILD_SESSION=1)
HUMAN=(env -u CLAUDE_CODE_CHILD_SESSION)

echo "── pre-commit 의 보호 브랜치"
R="$T/hook"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
echo x > "$R/README"; git -C "$R" add -A; git -C "$R" commit -q --no-verify -m init
echo y >> "$R/README"; git -C "$R" add -A

# hook <브랜치> <누가: SESSION|HUMAN> [변수=값 …] — 그 브랜치에서 훅을 실행한다. 린트는 이 테스트가 보는 것이 아니라
# 사람 쪽에서만 도구 없는 검사를 건너뛰게 한다(세션 쪽은 보호 브랜치 검사에서 먼저 끝나야 한다)
hook() {
  local br=$1 who=$2; shift 2
  git -C "$R" switch -q "$br" 2>/dev/null || git -C "$R" switch -qc "$br"
  local -a pre
  if [ "$who" = SESSION ]; then pre=("${SESSION[@]}"); else pre=("${HUMAN[@]}" KIT_ALLOW_MISSING_TOOLS=1); fi
  out=$(cd "$R" && "${pre[@]}" KIT_DIR="$KIT/common" "$@" bash "$HOOK" 2>&1); rc=$?
}
blocked() { [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '보호 브랜치입니다'; }
show() { printf '%s\n' "$out" | sed 's/^/      /' | head -12; }

hook main SESSION KIT_ALLOW_PROTECTED=1
if blocked && printf '%s\n' "$out" | grep -q '세션 밖' && printf '%s\n' "$out" | grep -q 'CLAUDE_CODE_CHILD_SESSION=1'; then
  ok "세션이 KIT_ALLOW_PROTECTED=1 을 붙여도 main 커밋을 막고 원인 변수와 세션 밖 터미널을 적는다"
else bad "세션이 KIT_ALLOW_PROTECTED=1 을 붙이면 main 커밋을 막고 원인 변수와 세션 밖 터미널을 적어야 한다(rc=$rc):"; show; fi
hook main HUMAN KIT_ALLOW_PROTECTED=1
printf '%s\n' "$out" | grep -q 'KIT_ALLOW_PROTECTED=1 로 허용' && ok "사람이 KIT_ALLOW_PROTECTED=1 을 붙이면 main 커밋을 허용한다" \
  || { bad "사람이 KIT_ALLOW_PROTECTED=1 을 붙이면 main 커밋을 허용해야 한다(rc=$rc):"; show; }

hook main SESSION KIT_PROTECTED_BRANCHES=
blocked && ok "세션이 KIT_PROTECTED_BRANCHES 를 비워도 main 을 보호한다" \
  || { bad "세션이 KIT_PROTECTED_BRANCHES 를 비우면 보호가 꺼졌다(rc=$rc):"; show; }
hook main SESSION KIT_PROTECTED_BRANCHES=develop
blocked && ok "세션이 KIT_PROTECTED_BRANCHES 에서 main 을 빼도 main 을 보호한다" \
  || { bad "세션이 KIT_PROTECTED_BRANCHES 에서 main 을 빼면 보호가 꺼졌다(rc=$rc):"; show; }
hook develop SESSION KIT_PROTECTED_BRANCHES=develop
blocked && ok "세션에서도 KIT_PROTECTED_BRANCHES 에 더한 브랜치(develop)는 보호한다" \
  || { bad "세션에서 KIT_PROTECTED_BRANCHES 에 더한 develop 을 보호하지 않았다(rc=$rc):"; show; }
hook main HUMAN KIT_PROTECTED_BRANCHES=develop
blocked && { bad "사람이 KIT_PROTECTED_BRANCHES 를 바꾸면 그 값을 따라야 한다(rc=$rc):"; show; } \
  || ok "사람이 KIT_PROTECTED_BRANCHES 를 바꾸면 그 값을 따른다"
# 막는 쪽만 보면 세션의 모든 커밋을 막는 변경도 통과한다. 세션이 보호 브랜치가 아닌 곳에서 하는 커밋은 훅 전체를 지나야 한다
hook feature SESSION
[ "$rc" -eq 0 ] && ok "세션이 보호 브랜치가 아닌 곳(feature)에서 커밋하면 훅을 통과한다" \
  || { bad "세션이 보호 브랜치가 아닌 곳(feature)에서 커밋하면 훅을 통과해야 한다(rc=$rc):"; show; }

echo "── 게이트의 도구 · 어댑터 없는 검사"
G="$T/gate"; mkdir -p "$G"
git init -q -b main "$G"
git -C "$G" config user.email t@example.com; git -C "$G" config user.name T
git -C "$G" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$G" --lang py,ts > "$T/install.log" 2>&1 || { bad "설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
# go 어댑터를 설치하지 않은 레포에 go 모듈이 생기면 게이트는 그 검사를 하지 못한다
mkdir -p "$G/backend"; printf 'module example.com/m\n\ngo 1.25\n' > "$G/backend/go.mod"
gate() { # <누가: SESSION|HUMAN> [변수=값 …]
  local who=$1; shift
  local -a pre
  if [ "$who" = SESSION ]; then pre=("${SESSION[@]}"); else pre=("${HUMAN[@]}"); fi
  out=$(cd "$G" && "${pre[@]}" "$@" bash .kit/gate/gate.sh --all 2>&1); rc=$?
}
skipped() { [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^gate — 건너뜀.*go(어댑터 없음)'; }

for v in KIT_ALLOW_MISSING_TOOLS=1 GATE_STRICT=0; do
  gate SESSION "$v"
  if [ "$rc" -ne 0 ] && ! skipped; then ok "세션이 $v 을 붙여도 어댑터 없는 검사를 건너뛰지 않고 실패한다"
  else bad "세션이 $v 을 붙이면 어댑터 없는 검사를 건너뛰었다(rc=$rc):"; show; fi
  gate HUMAN "$v"
  skipped && ok "사람이 $v 을 붙이면 어댑터 없는 검사를 건너뛴다" \
    || { bad "사람이 $v 을 붙이면 건너뛰어야 한다(rc=$rc):"; show; }
done
# 붙인 변수가 왜 듣지 않았는지 알려야 한다 — 실패 블록의 안내(아래)와 다른 줄이다. 원인인 변수 이름도 적는다. 세션이 띄운
# screen 같은 데서 그 값을 물려받은 터미널이면 사람이 세션 밖에 있다고 알면서 이 메시지를 받는다
gate SESSION KIT_ALLOW_MISSING_TOOLS=1
printf '%s\n' "$out" | grep -qE 'CLAUDE_CODE_CHILD_SESSION=1.*KIT_ALLOW_MISSING_TOOLS=1 을 받지 않습니다' \
  && ok "세션이 KIT_ALLOW_MISSING_TOOLS=1 을 붙이면 원인 변수와 함께 받지 않는다고 적는다" \
  || { bad "세션이 KIT_ALLOW_MISSING_TOOLS=1 을 붙이면 원인 변수와 함께 받지 않는다고 적어야 한다:"; show; }
# 변수를 붙이지 않아도 실패 블록의 안내가 세션에 맞아야 한다 — 받지 않는 변수로 건너뛰라고 적으면 세션은 그것을 붙여 본다
gate SESSION
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE 'CLAUDE_CODE_CHILD_SESSION=1.*사람이 세션 밖 터미널에서' \
  && ! printf '%s\n' "$out" | grep -q '불가피하게 건너뛰려면'; then
  ok "세션에서 어댑터 없는 검사가 실패하면 건너뛰는 법 대신 원인 변수와 세션 밖 터미널을 적는다"
else bad "세션에서 어댑터 없는 검사가 실패하면 건너뛰는 법이 아니라 원인 변수와 세션 밖 터미널을 적어야 한다(rc=$rc):"; show; fi
gate HUMAN
printf '%s\n' "$out" | grep -q '불가피하게 건너뛰려면' && ok "사람에게는 실패 블록이 건너뛰는 법을 적는다" \
  || { bad "사람에게는 실패 블록이 건너뛰는 법을 적어야 한다(rc=$rc):"; show; }

[ "$fail" = 0 ] && echo "  ✓ 세션이 붙인 우회 변수를 git 훅과 게이트가 받지 않는다"
exit $fail
