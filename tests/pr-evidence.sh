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
