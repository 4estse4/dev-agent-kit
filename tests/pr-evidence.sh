#!/usr/bin/env bash
# PR 본문 · 결정 코멘트의 증거를 명령이 덧붙이는가(`claude-code/skills/open-pr/evidence.sh`).
#
# **손으로 옮긴 출력이 잘렸다.** 한 PR 본문에서 18줄 출력의 앞 넷이 세 번 빠졌고, 결정
# 코멘트에는 돌린 것과 다른 명령이 옮겨졌다(`-q` 가 빠졌다). 규칙을 더 적는 것으로는 안
# 막혀서 옮기는 단계를 없앴다(이슈 #58). 그래서 둘을 본다.
# - 스크립트: 명령을 한 번 받아, 보이는 명령과 도는 명령이 같고 출력이 한 줄도 안 빠진다
# - 스킬: `open-pr` · `merge-pr` 이 출력을 손으로 붙이라고 시키지 않고 이 스크립트를 부른다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/claude-code/skills/open-pr/evidence.sh"
OPEN="$KIT/claude-code/skills/open-pr/SKILL.md"
MERGE="$KIT/claude-code/skills/merge-pr/SKILL.md"
T=$(mktemp -d)
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# run <조각 파일> <명령> — 스킬이 쓰는 모양 그대로 따옴표 heredoc 으로 넘긴다
run() {
  local f=$1 c=$2
  ( cd "$T" && printf '%s\n' "$c" | bash "$S" "$f" >/dev/null 2>&1 )
}

# ── 긴 출력이 한 줄도 안 빠진다 ──
c='for i in $(seq 1 20); do echo "line $i"; done'
run "$T/long.part" "$c"
n=$(grep -c '^line ' "$T/long.part" 2>/dev/null)
[ "${n:-0}" = 20 ] && ok "20줄 출력이 다 들어간다" || bad "20줄 출력이 다 들어간다 — ${n:-0}줄"
grep -qxF "\$ $c" "$T/long.part" 2>/dev/null && ok "보이는 명령이 넘긴 글자 그대로다" \
  || bad "보이는 명령이 넘긴 글자 그대로다"
grep -qx 'rc=0' "$T/long.part" 2>/dev/null && ok "종료 코드를 적는다" || bad "종료 코드를 적는다"
[ "$(head -1 "$T/long.part" 2>/dev/null)" = '```' ] && [ "$(tail -1 "$T/long.part" 2>/dev/null)" = '```' ] \
  && ok "코드 블록으로 감싼다" || bad "코드 블록으로 감싼다"

# ── 따옴표가 든 명령 ── 보이는 글자와 도는 글자가 같다
c=$'printf \'%s\\n\' "a b" \'c "d"\''
run "$T/quote.part" "$c"
grep -qxF "\$ $c" "$T/quote.part" 2>/dev/null && grep -qxF 'a b' "$T/quote.part" \
  && grep -qxF 'c "d"' "$T/quote.part" && ok "따옴표가 든 명령" || bad "따옴표가 든 명령"

# ── stderr 도 담는다 ──
run "$T/err.part" 'echo out; echo err >&2'
grep -qx 'out' "$T/err.part" 2>/dev/null && grep -qx 'err' "$T/err.part" \
  && ok "stderr 도 담는다" || bad "stderr 도 담는다"

# ── 실패한 명령 ── rc 를 적고 그 코드로 끝난다
( cd "$T" && printf '%s\n' 'echo half; exit 3' | bash "$S" "$T/fail.part" >/dev/null 2>&1 ); rc=$?
grep -qx 'rc=3' "$T/fail.part" 2>/dev/null && [ "$rc" = 3 ] \
  && ok "실패한 명령의 rc 를 적고 그 코드로 끝난다" || bad "실패한 명령의 rc 를 적고 그 코드로 끝난다 — rc=$rc"

# ── 여러 줄 명령 ── 둘째 줄부터는 이어짐 표시
run "$T/multi.part" $'echo one\necho two'
grep -qxF '$ echo one' "$T/multi.part" 2>/dev/null && grep -qxF '> echo two' "$T/multi.part" \
  && grep -qx 'two' "$T/multi.part" && ok "여러 줄 명령" || bad "여러 줄 명령"

# ── 출력에 ``` 가 들어도 블록이 안 깨진다 ──
run "$T/fence.part" "printf '%s\\n' 'a' '\`\`\`' 'b'"
open=$(head -1 "$T/fence.part" 2>/dev/null); close=$(tail -1 "$T/fence.part" 2>/dev/null)
[ "$open" = "$close" ] && [ "${#open}" -gt 3 ] && grep -qxF '```' "$T/fence.part" \
  && ok "출력의 \`\`\` 보다 긴 울타리" || bad "출력의 \`\`\` 보다 긴 울타리 — 여는 줄 '$open'"

# ── 덧붙인다 ── 앞의 블록을 덮지 않는다
run "$T/twice.part" 'echo first'
run "$T/twice.part" 'echo second'
grep -qx 'first' "$T/twice.part" 2>/dev/null && grep -qx 'second' "$T/twice.part" \
  && ok "덧붙인다" || bad "덧붙인다"

# ── 명령이 비면 아무것도 안 쓰고 실패한다 ──
( printf '\n' | bash "$S" "$T/empty.part" >/dev/null 2>&1 ); rc=$?
[ "$rc" != 0 ] && [ ! -e "$T/empty.part" ] && ok "빈 명령은 실패한다" || bad "빈 명령은 실패한다 — rc=$rc"

# ── 부른 자리에서 돈다 ──
run "$T/pwd.part" 'pwd -P'
grep -qxF "$(cd "$T" && pwd -P)" "$T/pwd.part" 2>/dev/null && ok "부른 자리에서 돈다" || bad "부른 자리에서 돈다"

# ── ask · deny 규칙 글자가 보이는 명령은 돌리지 않는다 ──
# evidence.sh 는 받은 글을 `bash -c` 로 돌린다. 권한 규칙은 그 안을 못 본다(공식 문서:
# "isn't a security boundary"). 누가 evidence.sh 를 허용하면 그 안의 `gh pr merge` 가 프롬프트
# 없이 돈다. 그래서 스크립트가 프로젝트 설정의 ask · deny 글자를 보고 거부한다.
R="$T/repo"
mkdir -p "$R/.claude" "$R/sub"
git -C "$R" init -q
cat > "$R/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(git log*)"],
  "ask": ["Bash(gh pr merge*)", "Bash(gh api:*)"],
  "deny": ["Bash(git push*--force*)"]}}
EOF
cat > "$R/.claude/settings.local.json" <<'EOF'
{"permissions": {"deny": ["Bash(rm -rf*)"]}}
EOF
refused() {   # refused <이름> <명령> [cwd]
  local f="$T/refuse-$RANDOM.part" rc err
  err=$( cd "${3:-$R}" && printf '%s\n' "$2" | bash "$S" "$f" 2>&1 >/dev/null ); rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$f" ] && printf '%s' "$err" | grep -q '돌리지 않는다'; then ok "$1"
  else bad "$1 — rc=$rc, 파일 $( [ -e "$f" ] && echo 있음 || echo 없음 ), $err"; fi
}
# 명령은 규칙 글자를 품은 `echo` 다. 글자로 막으므로 막히는 것은 같고, 가드가 빠져
# 돌아가도 아무것도 안 한다.
refused "ask 규칙 글자(gh pr merge)" 'echo gh pr merge 12 --squash'
refused "deny 규칙 글자(git push … --force)" 'echo git push origin main --force'
refused "사이에 공백이 더 든 글자" 'echo git  push   --force'
refused "이은 명령 뒤쪽의 글자" 'echo ok && echo gh pr merge 1'
refused "여러 줄 명령 둘째 줄의 글자" $'echo ok\necho gh pr merge 1'
refused "끝에 :* 를 쓴 규칙" 'echo gh api repos/x/y'
refused "settings.local.json 의 규칙" 'echo rm -rf build'
refused "하위 디렉터리에서 불러도 레포 설정을 본다" 'echo gh pr merge 3' "$R/sub"
f="$T/allowed.part"
( cd "$R" && printf '%s\n' 'git log --oneline -1 2>&1; echo done' | bash "$S" "$f" >/dev/null 2>&1 )
grep -qx 'done' "$f" 2>/dev/null && ok "규칙 글자가 없는 명령은 돈다" || bad "규칙 글자가 없는 명령은 돈다"
printf '{"permissions": ' > "$R/.claude/settings.json"
refused "설정을 못 읽으면 막는다" 'echo hi'

# ── 스킬이 손으로 붙이라고 시키지 않는다 ──
for f in "$OPEN" "$MERGE"; do
  name=$(basename "$(dirname "$f")")
  if tr '\n' ' ' < "$f" | grep -qE '출력을? *그대로 *붙인다|게이트 *출력을 *붙인다'; then
    bad "$name 이 출력을 손으로 붙이라고 시킨다"
  else ok "$name 이 출력을 손으로 붙이라고 시키지 않는다"; fi
  grep -q 'open-pr/evidence\.sh' "$f" && ok "$name 이 evidence.sh 를 부른다" || bad "$name 이 evidence.sh 를 부른다"
done
grep -qE 'gh pr create .*--body-file' "$OPEN" && ok "open-pr 이 본문을 --body-file 로 넘긴다" \
  || bad "open-pr 이 본문을 --body-file 로 넘긴다"

rm -rf "$T"
[ "$fail" = 0 ] && echo "  ✓ PR 본문 · 결정 코멘트의 증거를 명령이 덧붙인다"
exit $fail
