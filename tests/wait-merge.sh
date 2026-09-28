#!/usr/bin/env bash
# auto-merge 를 켠 PR 의 대기 스크립트(`wait_merge.sh`)가 사람이 봐야 할 일이 생겼을 때만 끝나는가. 그리고
# auto-merge 를 켠 명령 뒤에 PostToolUse 훅(`auto_merge_wait.sh`)이 그 스크립트를 켜라고 알리는가.
#
# 세션은 auto-merge 를 켠 뒤 이 스크립트를 백그라운드로 실행하고 턴을 끝낸다. 스크립트가 끝나면 Claude Code 가
# 세션을 깨운다. 그래서 끝나야 할 때 안 끝나면 세션은 머지를 모르고, 끝나지 않아야 할 때 끝나면 세션이 까닭
# 없이 깨어난다. 둘 다 본다.
#
# **네트워크를 안 쓴다.** PATH 앞에 둔 가짜 `gh` 가 `gh pr view` 마다 상태 파일의 다음 줄을 돌려주고
# (마지막 줄 뒤로는 마지막 줄을 되풀이한다. `FAIL` 줄은 조회 실패다), 계정의 레포 권한은 `perm-<계정>` 파일로
# 돌려준다(없으면 HTTP 404). 토큰 스크립트는 부른 것을 적는 가짜로 바꾼다. 조회 간격은 0 으로 줄인다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
S="$T/stub"
mkdir -p "$T/bin" "$T/hooks" "$T/cfg" "$S"
cp "$KIT/claude-code/hooks/wait_merge.sh" "$T/hooks/"
git init -q "$T/repo"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_REPO:-}" "$*" >> "$STUB/log"
case "$1 $2" in
  "pr view")
    n=$(( $(cat "$STUB/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/n"
    total=$(wc -l < "$STUB/states" | tr -d ' ')
    [ "$n" -gt "$total" ] && n=$total
    line=$(sed -n "${n}p" "$STUB/states")
    [ "$line" = FAIL ] && { echo 'stub: 조회 실패' >&2; exit 1; }
    printf '%s\n' "$line" ;;
  "api repos/{owner}/{repo}/collaborators/"*)
    [ -f "$STUB/perm-fail" ] && { echo 'gh: Server Error (HTTP 500)' >&2; exit 1; }
    login=${2#*/collaborators/}; login=${login%/permission}
    [ -f "$STUB/perm-$login" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    printf '{"permission": "%s"}\n' "$(cat "$STUB/perm-$login")" ;;
  *) echo "stub: 모르는 명령 $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
# 토큰 스크립트는 부른 것을 적고 끝나는 시각을 먼 뒤로 바꾼다
cat > "$T/hooks/bot_token.sh" <<'EOF'
#!/usr/bin/env bash
echo called >> "$STUB/token-log"
echo 2099-01-01T00:00:00Z > "$GH_CONFIG_DIR/expires"
echo "$GH_CONFIG_DIR"
EOF
fail=0

# st [<"키": 값> 조각]… — 기본 상태(열림 · auto-merge 켜짐 · 승인 모자람 · 검사 성공)에 조각의 키를 덮어 한 줄로
# 낸다. 조각을 중괄호로 묶는 것은 여기서 한다 — bash 3.2 는 `"$(… "{a, b}" …)"` 의 큰따옴표 안에서도 중괄호를
# 확장해 인자를 둘로 나눈다.
st() {
  python3 -c 'import json, sys
d = {"state": "OPEN", "mergeCommit": None, "baseRefName": "main",
     "autoMergeRequest": {"mergeMethod": "SQUASH", "enabledAt": "2026-09-28T10:00:00Z"},
     "headRefOid": "a1" * 20, "reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BLOCKED",
     "statusCheckRollup": [{"__typename": "CheckRun", "name": "tests", "status": "COMPLETED", "conclusion": "SUCCESS"}],
     "comments": [], "reviews": []}
d.update(json.loads("{" + ", ".join(sys.argv[1:]) + "}"))
print(json.dumps(d))' "$@"
}
# scenario <상태 줄>… — 가짜 gh 가 돌려줄 상태를 정하고 기록을 비운다
# 앞 시나리오가 적어 둔 것(켠 시각 · 켠 때의 head · 알린 글의 시각)도 지운다. restate 는 그것을 두고 상태만
# 바꾼다 — 같은 PR 을 다시 기다리는 경우다
scenario() {
  rm -f "$T/repo/.git/ai-kit-wait/"*.state
  restate "$@"
}
restate() {
  rm -rf "$S"; mkdir -p "$S"
  printf '%s\n' "$@" > "$S/states"
  echo 2099-01-01T00:00:00Z > "$T/cfg/expires"
}
# run <인자>… — 스크립트를 실행해 출력을 $OUT, 종료 코드를 $RC 에 둔다. 20초 안에 안 끝나면 142 다
run() {
  OUT=$(cd "$T/repo" && PATH="$T/bin:$PATH" STUB="$S" GH_CONFIG_DIR="$T/cfg" WAIT_MERGE_INTERVAL=0 \
    perl -e 'alarm shift @ARGV; exec @ARGV' 20 bash "$T/hooks/wait_merge.sh" "$@" 2>&1)
  RC=$?
}
views() { local n; n=$(grep -c '|pr view' "$S/log" 2>/dev/null); echo "${n:-0}"; }
# check <이름> <기대 까닭> <기대 종료 코드> [조회 수] [출력에 있어야 할 글자]
check() {
  local got=${OUT%%:*} n
  n=$(views)
  if [ "$got" != "$2" ] || [ "$RC" != "$3" ] || { [ -n "${4:-}" ] && [ "$n" != "$4" ]; } \
    || { [ -n "${5:-}" ] && ! printf '%s' "$OUT" | grep -qF -- "$5"; }; then
    echo "  ✗ $1 — 기대 「$2」 rc=$3 조회 ${4:-?}번${5:+ 「$5」}, 실제 rc=$RC 조회 ${n}번: $OUT"; fail=1
  else
    echo "  ✓ $1 ($2, 조회 ${n}번)"
  fi
}
# auto-merge 는 10:00 에 켰다(st 의 기본값). c0 은 그 전에, c1 은 그 뒤에 달린 사람 코멘트다
C='"comments": [{"id": "c0", "author": {"login": "person"}, "url": "https://x/c0", "createdAt": "2026-09-28T09:00:00Z"}]'
C1='"comments": [{"id": "c0", "author": {"login": "person"}, "url": "https://x/c0", "createdAt": "2026-09-28T09:00:00Z"}, {"id": "c1", "author": {"login": "person"}, "url": "https://x/c1", "createdAt": "2026-09-28T10:05:00Z"}]'
MERGED=$(st '"state": "MERGED", "mergeCommit": {"oid": "58d7886abcdef"}')
OPEN=$(st)
APPROVED='"reviewDecision": "APPROVED", "reviews": [{"id": "r1", "author": {"login": "person"}, "state": "APPROVED", "submittedAt": "2026-09-28T10:05:00Z"}]'
PENDING='"statusCheckRollup": [{"__typename": "CheckRun", "name": "tests", "status": "IN_PROGRESS", "conclusion": ""}]'

echo "── 끝나는 까닭"
scenario "$MERGED"; run 7
check "첫 조회에서 이미 머지됐으면 바로 끝난다" 머지됨 0 1 58d7886
scenario "$OPEN" "$OPEN" "$MERGED"; run 7
check "열린 채 기다리다 머지되면 끝난다" 머지됨 0 3
scenario "$OPEN" "$(st '"state": "MERGED", "autoMergeRequest": null, "headRefOid": "'"$(printf 'b2%.0s' {1..20})"'"')"; run 7
check "auto-merge 가 없고 head 가 바뀐 채 머지됐어도 머지됨이다" 머지됨 0 2
scenario "$OPEN" "$(st '"state": "CLOSED", "autoMergeRequest": null')"; run 7
check "머지 없이 닫히면 끝난다" 닫힘 1 2
scenario "$OPEN" "$OPEN" "$(st '"autoMergeRequest": null')"; run 7
check "auto-merge 가 꺼지면 끝난다" "auto-merge 꺼짐" 1 3
scenario "$OPEN" "$(st '"headRefOid": "'"$(printf 'b2%.0s' {1..20})"'"')"; run 7
check "head 가 바뀌면 끝난다" "head 바뀜" 1 2 b2b2b2b
# 기다리던 세션이 끝난 사이에 누가 푸시했으면, 다시 실행한 대기의 첫 조회에서 이미 head 가 다르다
B2=$(printf 'b2%.0s' {1..20})
scenario "$OPEN" "$MERGED"; run 7
restate "$(st '"headRefOid": "'"$B2"'"')"; run 7
check "다시 실행해도 auto-merge 를 켠 때의 head 와 견준다" "head 바뀜" 1 1 b2b2b2b
restate "$(st '"headRefOid": "'"$B2"'", "autoMergeRequest": {"mergeMethod": "SQUASH", "enabledAt": "2026-09-28T11:00:00Z"}')" "$MERGED"; run 7
check "auto-merge 를 다시 켰으면 그때의 head 를 기준으로 삼는다" 머지됨 0 2

echo "── 사람의 글"
scenario "$(st "$C")" "$(st "$C1")"; echo admin > "$S/perm-person"; run 7
check "사람 계정의 새 코멘트면 끝난다" "사람의 글" 1 2 https://x/c1
scenario "$(st "$C")" "$(st "$C")" "$MERGED"; echo write > "$S/perm-person"; run 7
check "auto-merge 를 켜기 전의 사람 코멘트로는 끝나지 않는다" 머지됨 0 3
# 세션을 다시 시작한 뒤 대기를 실행한 경우다. 기다리지 않던 사이에 달린 글도 새 글이다
scenario "$(st "$C1")"; echo admin > "$S/perm-person"; run 7
check "auto-merge 를 켠 뒤 대기를 실행하기 전에 달린 사람 코멘트로도 끝난다" "사람의 글" 1 1 https://x/c1
# 사람의 글을 알린 뒤 계속 기다리려고 다시 실행한 경우다. 알린 글로 곧바로 다시 끝나면 기다릴 수 없다
restate "$(st "$C1")" "$MERGED"; echo admin > "$S/perm-person"; run 7
check "알린 사람의 글은 다시 실행해도 다시 알리지 않는다" 머지됨 0 2
C2='"comments": [{"id": "c1", "author": {"login": "person"}, "url": "https://x/c1", "createdAt": "2026-09-28T10:05:00Z"}, {"id": "c2", "author": {"login": "person"}, "url": "https://x/c2", "createdAt": "2026-09-28T10:07:00Z"}]'
restate "$(st "$C2")"; echo admin > "$S/perm-person"; run 7
check "알린 글 뒤에 달린 사람의 글은 다시 실행하면 알린다" "사람의 글" 1 1 https://x/c2
# 두 글이 함께 있으면 먼저 달린 것부터 하나씩 알린다
C3='"comments": [{"id": "c3", "author": {"login": "person"}, "url": "https://x/c3", "createdAt": "2026-09-28T10:09:00Z"}], "reviews": [{"id": "r3", "author": {"login": "person"}, "state": "COMMENTED", "submittedAt": "2026-09-28T10:08:00Z"}]'
scenario "$(st "$C3")"; echo admin > "$S/perm-person"; run 7
check "코멘트와 리뷰가 함께 있으면 먼저 달린 리뷰부터 알린다" "사람의 글" 1 1 COMMENTED
restate "$(st "$C3")"; echo admin > "$S/perm-person"; run 7
check "다시 실행하면 그다음 글을 알린다" "사람의 글" 1 1 https://x/c3
# 탈퇴한 계정의 글은 author 가 null 이다. 같은 시각의 글과 나란히 있어도 조회 실패로 세지 않는다
GH='"comments": [{"id": "g1", "author": null, "url": "https://x/g1", "createdAt": "2026-09-28T10:05:00Z"}, {"id": "c1", "author": {"login": "person"}, "url": "https://x/c1", "createdAt": "2026-09-28T10:05:00Z"}]'
scenario "$(st "$GH")"; echo admin > "$S/perm-person"; run 7
check "글쓴이가 없는 글이 같은 시각에 있어도 사람의 글을 알린다" "사람의 글" 1 1 https://x/c1
# 새 코멘트가 달린 상태를 여섯 번 본다 — 권한 조회의 404 를 실패로 세면 다섯 번째에 조회 실패로 끝난다
BC=$(st '"comments": [{"id": "c1", "author": {"login": "claude-helper"}, "url": "https://x/c1", "createdAt": "2026-09-28T10:05:00Z"}, {"id": "c2", "author": {"login": "reader"}, "url": "https://x/c2", "createdAt": "2026-09-28T10:06:00Z"}]')
scenario "$OPEN" "$BC" "$BC" "$BC" "$BC" "$BC" "$BC" "$MERGED"
echo read > "$S/perm-reader"; run 7
check "봇 · 쓰기 권한 없는 계정의 새 코멘트로는 끝나지 않는다" 머지됨 0 8
for s in COMMENTED CHANGES_REQUESTED; do
  scenario "$OPEN" "$(st '"reviews": [{"id": "r1", "author": {"login": "person"}, "state": "'$s'", "submittedAt": "2026-09-28T10:05:00Z"}]')"
  echo admin > "$S/perm-person"; run 7
  check "사람 계정의 새 리뷰($s)면 끝난다" "사람의 글" 1 2 "$s"
done

echo "── Approve 됐는데 머지되지 않음"
AP=$(st "$APPROVED" "$PENDING")
scenario "$OPEN" "$AP" "$AP" "$AP" "$MERGED"; echo admin > "$S/perm-person"; run 7
check "사람의 Approve 로는 끝나지 않고, 검사가 실행 중이면 기다린다" 머지됨 0 5
AS=$(st "$APPROVED" '"statusCheckRollup": [{"__typename": "StatusContext", "context": "ci/legacy", "state": "PENDING"}]')
scenario "$OPEN" "$AS" "$AS" "$AS" "$MERGED"; echo admin > "$S/perm-person"; run 7
check "커밋 상태(StatusContext)가 대기 중이어도 기다린다" 머지됨 0 5
scenario "$OPEN" "$(st "$APPROVED" '"mergeStateStatus": "BEHIND"')"; echo admin > "$S/perm-person"; run 7
check "Approve 됐는데 뒤처졌으면 두 번 본 뒤 끝난다" "머지되지 않음" 1 3 BEHIND
scenario "$OPEN" "$(st "$APPROVED" '"mergeStateStatus": "CLEAN"')" "$MERGED"; echo admin > "$S/perm-person"; run 7
check "Approve 직후 한 번 보인 머지 전 상태로는 끝나지 않는다" 머지됨 0 3
FAILED='"statusCheckRollup": [{"__typename": "CheckRun", "name": "tests", "status": "COMPLETED", "conclusion": "FAILURE"}, {"__typename": "StatusContext", "context": "ci/legacy", "state": "ERROR"}]'
scenario "$OPEN" "$(st "$APPROVED" "$FAILED")"; echo admin > "$S/perm-person"; run 7
check "Approve 됐는데 검사가 실패했으면 실패한 검사 이름을 적고 끝난다" "머지되지 않음" 1 3 "tests, ci/legacy"
AU=$(st "$APPROVED" '"mergeStateStatus": "UNKNOWN"')
scenario "$OPEN" "$AU" "$AU" "$AU" "$MERGED"; echo admin > "$S/perm-person"; run 7
check "Approve 됐는데 GitHub 이 아직 계산 중(UNKNOWN)이면 기다린다" 머지됨 0 5

echo "── 조회 실패"
scenario FAIL FAIL FAIL FAIL FAIL; run 7
check "조회가 5번 잇달아 실패하면 끝난다" "조회 실패" 1 5 "조회 실패"
scenario FAIL FAIL FAIL FAIL "$OPEN" FAIL FAIL FAIL FAIL "$MERGED"; run 7
check "4번 실패한 뒤 조회되면 계속 기다린다" 머지됨 0 10
scenario "$OPEN" "$(st "$C1")"; touch "$S/perm-fail"; run 7
check "새 글쓴이의 권한을 조회하지 못하면 조회 실패로 센다" "조회 실패" 1 6

echo "── 토큰"
# expires_in <분> — 봇 디렉터리의 토큰이 지금부터 그 분 뒤에 끝나게 한다
expires_in() {
  python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1" > "$T/cfg/expires"
}
scenario "$OPEN" "$MERGED"; expires_in 5; run 7
check "토큰이 10분 안에 끝나도 조회를 이어 간다" 머지됨 0 2
if [ -s "$S/token-log" ]; then echo "  ✓ 토큰이 10분 안에 끝나면 조회 전에 새로 받는다"; else echo "  ✗ 토큰이 10분 안에 끝나는데 새로 받지 않았다"; fail=1; fi
scenario "$OPEN" "$MERGED"; expires_in 50; run 7
if [ ! -e "$S/token-log" ]; then echo "  ✓ 토큰이 50분 남았으면 새로 받지 않는다"; else echo "  ✗ 토큰이 50분 남았는데 새로 받았다"; fail=1; fi

echo "── 인자와 잠금"
scenario "$OPEN" "$(st "$C1")"; echo admin > "$S/perm-person"; run 7 -R o/r
check "-R 을 받는다" "사람의 글" 1 2
if grep -q '^o/r|pr view 7 -R o/r ' "$S/log" && grep -q '^o/r|api repos/{owner}/{repo}/collaborators/person/permission' "$S/log"; then
  echo "  ✓ -R 의 레포를 gh pr view 인자와 gh api 의 GH_REPO 로 전달한다"
else echo "  ✗ -R 의 레포를 전달하지 않았다: $(cat "$S/log")"; fail=1; fi
scenario "$OPEN"; run; check "PR 번호가 없으면 사용법을 출력한다" 사용 2 0
scenario "$OPEN"; run 7 8; check "PR 번호가 둘이면 사용법을 출력한다" 사용 2 0

scenario "$OPEN"
( cd "$T/repo" && PATH="$T/bin:$PATH" STUB="$S" GH_CONFIG_DIR="$T/cfg" WAIT_MERGE_INTERVAL=0.2 \
  bash "$T/hooks/wait_merge.sh" 7 > "$T/first.txt" 2>&1 ) &
first=$!
for _ in $(seq 50); do [ "$(views)" -ge 1 ] && break; sleep 0.1; done
run 7
check "같은 PR 을 기다리는 스크립트가 실행 중이면 바로 끝난다" "이미 기다림" 0
kill "$(cat "$T/repo/.git/ai-kit-wait/7" 2>/dev/null)" "$first" 2>/dev/null; wait "$first" 2>/dev/null
scenario "$MERGED"; run 7
check "멈춘 대기 스크립트의 잠금은 다음 실행을 막지 않는다" 머지됨 0 1
sleep 0 & dead=$!; wait "$dead"
mkdir -p "$T/repo/.git/ai-kit-wait"; echo "$dead" > "$T/repo/.git/ai-kit-wait/7"
scenario "$MERGED"; run 7
check "없는 프로세스를 가리키는 잠금은 무시한다" 머지됨 0 1
sleep 30 & other=$!
echo "$other" > "$T/repo/.git/ai-kit-wait/7"
scenario "$MERGED"; run 7
check "대기 스크립트가 아닌 프로세스를 가리키는 잠금은 무시한다" 머지됨 0 1
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

echo "── auto-merge 를 켠 뒤의 안내(PostToolUse 훅)"
# 설치된 레포의 모양(.claude/hooks/)에 훅을 두고 Claude Code 가 부르는 모양으로 부른다
mkdir -p "$T/repo/.claude/hooks"
cp "$KIT/claude-code/hooks/auto_merge_wait.sh" "$T/repo/.claude/hooks/" 2>/dev/null
# hint <이름> <명령> <기대: 없음 | 출력에 있어야 할 글자>
hint() {
  local out
  out=$(python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "cwd": sys.argv[1],
    "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[2]},
    "tool_response": {"stdout": "", "stderr": "", "interrupted": False}}))' "$T/repo" "$2" \
    | (cd "$T/repo" && bash .claude/hooks/auto_merge_wait.sh) 2>&1)
  if [ "$3" = 없음 ]; then
    if [ -z "$out" ]; then echo "  ✓ $1 (안내 없음)"; else echo "  ✗ $1 — 안내가 없어야 하는데 있다: $out"; fail=1; fi
    return
  fi
  if printf '%s' "$out" | python3 -c 'import json, sys
o = json.load(sys.stdin)["hookSpecificOutput"]
assert o["hookEventName"] == "PostToolUse"
assert sys.argv[1] in o["additionalContext"] and "run_in_background" in o["additionalContext"]' "$3" 2>/dev/null; then
    echo "  ✓ $1 (「$3」)"
  else echo "  ✗ $1 — 「$3」와 run_in_background 를 담은 additionalContext 가 없다: $out"; fail=1; fi
}
hint "auto-merge 를 켜면 대기 스크립트를 켜라고 알린다" \
  'gh pr merge 7 --auto --squash --match-head-commit abc --subject "feat: x (#7)" --body "- PR: u"' \
  'bash .claude/hooks/wait_merge.sh 7'
hint "-R 을 대기 스크립트에 전달한다" 'gh pr merge 7 -R o/r --auto --squash' 'wait_merge.sh 7 -R o/r'
hint "--auto=true 도 켠 것이다" 'gh pr merge 7 --auto=true --squash' 'wait_merge.sh 7'
hint "앞에 다른 명령이 있어도 알아본다" 'cd /x && gh pr merge 7 --squash --auto' 'wait_merge.sh 7'
hint "PR 번호가 없으면 번호를 넣으라고 알린다" 'gh pr merge --auto --squash' 'wait_merge.sh <PR 번호>'
hint "auto-merge 를 끄는 명령에는 알리지 않는다" 'gh pr merge 7 --disable-auto' 없음
hint "--auto=false 에는 알리지 않는다" 'gh pr merge 7 --auto=false --squash' 없음
hint "auto-merge 없는 머지에는 알리지 않는다" 'gh pr merge 7 --squash' 없음
hint "플래그 값 안의 --auto 는 켠 것이 아니다" 'gh pr merge 7 --squash --body "use --auto next time"' 없음
hint "값을 받는 플래그의 값은 PR 번호가 아니다" 'gh pr merge --auto --subject "feat: x (#7)" 7' 'wait_merge.sh 7'
hint "명령의 인자인 글자는 켠 것이 아니다" 'grep -n "gh pr merge 7 --auto" notes.md' 없음
hint "다른 gh 명령에는 알리지 않는다" 'gh pr view 7 --json autoMergeRequest' 없음

[ "$fail" = 0 ] && echo "  ✓ 대기 스크립트는 사람이 봐야 할 일이 생겼을 때만 끝난다"
exit "$fail"
