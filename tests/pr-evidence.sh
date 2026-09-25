#!/usr/bin/env bash
# PR 본문 · 결정 코멘트의 증거를 명령이 덧붙이는가(`claude-code/skills/open-pr/evidence.sh`).
#
# **손으로 옮긴 출력이 잘렸다.** 한 PR 본문에서 18줄 출력의 앞 넷이 세 번 빠졌고, 결정
# 코멘트에는 실행한 것과 다른 명령이 옮겨졌다(`-q` 가 빠졌다). 규칙을 더 적는 것으로는 안
# 막혀서 옮기는 단계를 없앴다(이슈 #58). 그래서 둘을 본다.
# - 스크립트: 명령을 한 번 받아, 보이는 명령과 실행되는 명령이 같고 출력이 한 줄도 안 빠진다
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

# run <조각 파일> <명령> — 스킬이 쓰는 모양 그대로 따옴표 heredoc 으로 전달한다
run() {
  local f=$1 c=$2
  ( cd "$T" && printf '%s\n' "$c" | bash "$S" "$f" >/dev/null 2>&1 )
}

# ── 긴 출력이 한 줄도 안 빠진다 ──
c='for i in $(seq 1 20); do echo "line $i"; done'
run "$T/long.part" "$c"
n=$(grep -c '^line ' "$T/long.part" 2>/dev/null)
[ "${n:-0}" = 20 ] && ok "20줄 출력이 다 들어간다" || bad "20줄 출력이 다 들어간다 — ${n:-0}줄"
grep -qxF "\$ $c" "$T/long.part" 2>/dev/null && ok "보이는 명령이 전달한 글자 그대로다" \
  || bad "보이는 명령이 전달한 글자 그대로다"
grep -qx 'rc=0' "$T/long.part" 2>/dev/null && ok "종료 코드를 적는다" || bad "종료 코드를 적는다"
[ "$(head -1 "$T/long.part" 2>/dev/null)" = '```' ] && [ "$(tail -1 "$T/long.part" 2>/dev/null)" = '```' ] \
  && ok "코드 블록으로 감싼다" || bad "코드 블록으로 감싼다"

# ── 따옴표가 든 명령 ── 보이는 글자와 실행되는 글자가 같다
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
# 출력에만 든 경우와 명령에만 든 경우를 따로 본다. 둘 다 든 위 경우는 한쪽만 보는 울타리도
# 통과시킨다.
run "$T/fence-out.part" "printf '\\140\\140\\140\\n'"
open=$(head -1 "$T/fence-out.part" 2>/dev/null); close=$(tail -1 "$T/fence-out.part" 2>/dev/null)
[ "$open" = "$close" ] && [ "${#open}" -gt 3 ] && ok "출력에만 든 \`\`\`" \
  || bad "출력에만 든 \`\`\` — 여는 줄 '$open'"
run "$T/fence-cmd.part" "echo '\`\`\`' >/dev/null; echo x"
open=$(head -1 "$T/fence-cmd.part" 2>/dev/null); close=$(tail -1 "$T/fence-cmd.part" 2>/dev/null)
[ "$open" = "$close" ] && [ "${#open}" -gt 3 ] && ok "명령에만 든 \`\`\`" \
  || bad "명령에만 든 \`\`\` — 여는 줄 '$open'"

# ── 덧붙이기가 실패하면 성공으로 끝나지 않는다 ──
( cd "$T" && printf '%s\n' 'echo hi' | bash "$S" "$T/no-such-dir/x.part" >/dev/null 2>&1 ); rc=$?
[ "$rc" != 0 ] && ok "덧붙이지 못하면 0 이 아니다" || bad "덧붙이지 못하면 0 이 아니다 — rc=$rc"

# ── 덧붙인다 ── 앞의 블록을 덮지 않는다
run "$T/twice.part" 'echo first'
run "$T/twice.part" 'echo second'
grep -qx 'first' "$T/twice.part" 2>/dev/null && grep -qx 'second' "$T/twice.part" \
  && ok "덧붙인다" || bad "덧붙인다"

# ── 명령이 비면 아무것도 안 쓰고 실패한다 ──
( printf '\n' | bash "$S" "$T/empty.part" >/dev/null 2>&1 ); rc=$?
[ "$rc" != 0 ] && [ ! -e "$T/empty.part" ] && ok "빈 명령은 실패한다" || bad "빈 명령은 실패한다 — rc=$rc"

# ── 부른 자리에서 실행된다 ──
run "$T/pwd.part" 'pwd -P'
grep -qxF "$(cd "$T" && pwd -P)" "$T/pwd.part" 2>/dev/null && ok "부른 자리에서 실행된다" || bad "부른 자리에서 실행된다"

# ── ask · deny 규칙 글자가 보이는 명령은 실행하지 않는다 ──
# evidence.sh 는 받은 글을 `bash -c` 로 실행한다. 권한 규칙은 그 안을 못 본다(공식 문서:
# "isn't a security boundary"). 누가 evidence.sh 를 허용하면 그 안의 `gh pr merge` 가 프롬프트
# 없이 실행된다. 그래서 스크립트가 프로젝트 설정의 ask · deny 글자를 보고 거부한다.
R="$T/repo"
mkdir -p "$R/.claude" "$R/sub"
git -C "$R" init -q
cat > "$R/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(git log*)"],
  "ask": ["Bash(gh pr merge*)", "Bash(gh api:*)"],
  "deny": ["Bash(git push*--force*)"]}}
EOF
cat > "$R/.claude/settings.local.json" <<'EOF'
{"permissions": {"deny": ["Bash(rm *)", "Bash(npm run *--prod*)", "Bash(* --help *)"]}}
EOF
# 거부된 명령은 **실행되지 않아야** 한다. 명령 앞에 흔적 파일을 만드는 `touch` 를 붙여, 거부했다고
# 말하면서 먼저 실행한 모양을 찾아낸다. 뒤의 글자는 규칙 글자를 품은 `echo` 라 가드가 빠져
# 실행되어도 아무것도 안 한다.
refused() {   # refused <이름> <명령> [cwd]
  local f="$T/refuse-$RANDOM.part" m="$T/ran-$RANDOM" rc err
  err=$( cd "${3:-$R}" && printf 'touch %s; %s\n' "$m" "$2" | bash "$S" "$f" 2>&1 >/dev/null ); rc=$?
  if [ "$rc" != 0 ] && [ ! -e "$f" ] && [ ! -e "$m" ] && printf '%s' "$err" | grep -q '실행하지 않는다' \
     && printf '%s' "$err" | grep -q '글로 적는다'; then ok "$1"
  else bad "$1 — rc=$rc, 조각 $( [ -e "$f" ] && echo 있음 || echo 없음 ), 실행됐나 $( [ -e "$m" ] && echo 실행됐다 || echo 실행되지 않았다 ), $err"; fi
}
refused "ask 규칙 글자(gh pr merge)" 'echo gh pr merge 12 --squash'
refused "deny 규칙 글자(git push … --force)" 'echo git push origin main --force'
refused "사이에 공백이 더 든 글자" 'echo git  push   --force'
refused "이은 명령 뒤쪽의 글자" 'echo ok && echo gh pr merge 1'
refused "여러 줄 명령 둘째 줄의 글자" $'echo ok\necho gh pr merge 1'
refused "끝에 :* 를 쓴 규칙" 'echo gh api repos/x/y'
refused "settings.local.json 의 규칙" 'echo rm -rf build'
refused "하위 디렉터리에서 불러도 레포 설정을 본다" 'echo gh pr merge 3' "$R/sub"
# 끝이 ` *` 인 규칙은 맨 명령에도 적용된다. 공식 문서: "A `*` at the end, with a space before it,
# also matches the bare command." 구분자가 바로 붙은 모양도 같다.
refused "끝 ' *' 규칙의 맨 명령" 'echo x; echo rm'
refused "끝 ' *' 규칙 뒤에 ; 가 붙음" 'echo rm;echo x'
refused "끝 ' *' 규칙 뒤에 ) 가 붙음" 'echo "$(echo rm)"'
refused "끝 :* 규칙의 맨 명령" 'echo gh api'
refused "가운데 ' *' 규칙" 'echo npm run build --prod'
# 맨 명령 바로 뒤에 올 수 있는 글자마다 하나씩. 빠진 글자가 있으면 그 모양이 지나간다
refused "끝 ' *' 규칙 뒤에 && 가 붙음" 'echo rm&&echo x'
refused "끝 ' *' 규칙 뒤에 | 가 붙음" 'echo rm|cat'
refused "끝 ' *' 규칙 뒤에 따옴표가 붙음(sh -c 'rm' 모양)" "echo 'rm'"
refused "끝 ' *' 규칙 뒤에 백틱이 붙음" 'echo `echo rm`'
refused "끝 ' *' 규칙 뒤에 리다이렉트가 붙음" 'echo rm>/dev/null'
refused "끝 ' *' 규칙 뒤에 입력 리다이렉트가 붙음" 'echo rm</dev/null'
# 맨 명령은 끝 `*` 가 규칙의 유일한 와일드카드일 때만 맞는다. 공식 문서: "`Bash(* --help *)`
# matches `npm --help x` but not `npm --help`."
refused "와일드카드가 둘인 규칙의 뒤 글자" 'echo npm --help x'
# worktree 세션은 원래 체크아웃의 settings.local.json 을 쓴다(공식 문서 settings.md: "In a
# worktree, it uses the file at the main checkout's root."). 그 파일은 worktree 에 없다.
git -C "$R" add .claude/settings.json && git -C "$R" -c user.email=t@example.com -c user.name=T commit -q -m init
git -C "$R" worktree add -q "$R/.claude/worktrees/w1" 2>/dev/null
refused "worktree 에서 원래 체크아웃의 settings.local.json 규칙" 'echo rm -rf build' "$R/.claude/worktrees/w1"
# 규칙 글자가 낱말 속이나 다른 모양으로만 든 명령은 실행된다. 공식 문서: "The space before a
# trailing `*` is part of the rule. `Bash(ls *)` requires a space after `ls`, so `lsof` doesn't match."
runs() {   # runs <이름> <명령>
  local f="$T/runs-$RANDOM.part"
  ( cd "$R" && printf '%s; echo done\n' "$2" | bash "$S" "$f" >/dev/null 2>&1 )
  grep -qx 'done' "$f" 2>/dev/null && ok "$1" || bad "$1 — $(cat "$f" 2>/dev/null)"
}
runs "규칙 글자가 없는 명령은 실행된다" 'git log --oneline -1 2>&1'
runs "Bash(rm *) 가 --format 을 막지 않는다" "git log --format='%h %s' -1 2>&1"
runs "Bash(rm *) 가 normal · platform 을 막지 않는다" 'echo normal platform'
runs "Bash(rm *) 가 낱말 끝의 rm 을 막지 않는다" 'echo farm tools'
runs "Bash(rm *) 가 rmdir 을 막지 않는다(* 앞 공백)" 'echo rmdir x'
runs "Bash(gh api:*) 가 gh apix 를 막지 않는다(:* 는 공백 *)" 'echo gh apix'
runs "Bash(rm *) 가 --rm 을 막지 않는다(앞 경계에 -)" 'echo docker compose run --rm app pytest'
runs "가운데 ' *' 규칙이 공백 없는 자리를 막지 않는다" 'echo npm runx --prod'
runs "와일드카드가 둘인 규칙은 맨 명령을 막지 않는다" 'echo npm --help'
printf '{"permissions": ' > "$R/.claude/settings.json"
refused "설정을 못 읽으면 막는다" 'echo hi'

# ── 파이썬 heredoc 이 명령 치환 안에 있지 않다 ──
# macOS 기본 bash(3.2)는 명령 치환 안의 heredoc 에서 짝 없는 따옴표 · 백틱을 세어 스크립트 전체를
# 구문 오류로 죽인다. CI 는 ubuntu(bash 5)라 그것을 못 보므로, 자리를 글자로 본다.
# 줄넘김(`\`)으로 이어진 명령 치환도 보도록 줄을 이어 붙여서 찾는다.
if tr '\n' ' ' < "$S" | grep -qE '\$\([^)]*<<'; then
  bad "파이썬 heredoc 이 명령 치환 밖에 있다 — $(tr '\n' ' ' < "$S" | grep -oE '\$\([^)]*<<' | head -1 | cut -c1-80)"
else ok "파이썬 heredoc 이 명령 치환 밖에 있다"; fi
bash -n "$S" && ok "이 셸($BASH_VERSION)로 구문 검사를 통과한다" || bad "이 셸($BASH_VERSION)로 구문 검사를 통과한다"

# ── 스킬이 손으로 붙이라고 시키지 않는다 ──
for f in "$OPEN" "$MERGE"; do
  name=$(basename "$(dirname "$f")")
  if tr '\n' ' ' < "$f" | grep -qE '출력을? *그대로 *붙인다|게이트 *출력을 *붙인다|출력은 *(\*\*)?그대로(\*\*)? *옮긴다'; then
    bad "$name 이 출력을 손으로 붙이라고 시킨다"
  else ok "$name 이 출력을 손으로 붙이라고 시키지 않는다"; fi
  grep -q 'open-pr/evidence\.sh' "$f" && ok "$name 이 evidence.sh 를 부른다" || bad "$name 이 evidence.sh 를 부른다"
  # 거부된 뒤 갈 길을 스킬이 말한다. 없으면 세션은 직접 실행해 손으로 옮긴다
  tr '\n' ' ' < "$f" | grep -qE '(글로 *적는다|글로 적는다)' && ok "$name 이 거부된 명령의 갈 길을 말한다" \
    || bad "$name 이 거부된 명령의 갈 길을 말한다"
  grep -q 'awk 1' "$f" && ok "$name 이 조각을 awk 1 로 잇는다" || bad "$name 이 조각을 awk 1 로 잇는다"
done
grep -qE 'gh pr create .*--body-file' "$OPEN" && ok "open-pr 이 본문을 --body-file 로 전달한다" \
  || bad "open-pr 이 본문을 --body-file 로 전달한다"

# ── 조각을 이을 때 끝 줄바꿈이 없어도 울타리가 앞 줄에 붙지 않는다 ──
# `Write` 로 쓴 조각이 줄바꿈 없이 끝나면 `cat` 은 다음 조각의 여는 울타리를 그 줄에 붙인다.
# 스킬이 적은 잇는 명령을 그대로 꺼내 실행한다.
J="$T/join"; mkdir -p "$J"
printf '## 검증' > "$J/10-head.part"
( cd "$T" && printf '%s\n' 'echo hi' | bash "$S" "$J/20-ev.part" >/dev/null 2>&1 )
join=$(grep -oE '(cat|awk 1) <디렉터리>/\*\.part > <디렉터리>/body\.md' "$OPEN" | head -1)
if [ -z "$join" ]; then bad "open-pr 에서 조각 잇는 명령을 못 찾았다"
else
  ( cd "$J" && eval "${join//<디렉터리>/.}" )
  sed -n 2p "$J/body.md" | grep -qx '```' && ok "잇기 — 줄바꿈 없는 조각 뒤 울타리가 제 줄에 있다" \
    || bad "잇기 — 줄바꿈 없는 조각 뒤 울타리가 제 줄에 있다: $(head -2 "$J/body.md" | tr '\n' '|')"
fi

rm -rf "$T"
[ "$fail" = 0 ] && echo "  ✓ PR 본문 · 결정 코멘트의 증거를 명령이 덧붙인다"
exit $fail
