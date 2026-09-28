#!/usr/bin/env bash
# 레포에 봇 설정(`.claude/bot.json`)이 있을 때 세션의 gh 를 봇 계정에 연결하고, 그 연결을 벗어나는
# 쓰기를 막는가.
#
# 세 훅을 Claude Code 가 부르는 모양으로 부른다 — SessionStart 의 `bot_session.sh` 와 PreToolUse 의
# `bot_guard.sh` 에는 표준입력에 JSON 을 넣고, `CLAUDE_ENV_FILE` 을 준다. 토큰 스크립트
# `bot_token.sh` 는 두 훅이 부르는 것을 지나가게 한다.
#
# **네트워크와 진짜 개인키를 안 쓴다.** 개인키는 이 테스트가 만든 버릴 RSA 키이고, PATH 앞에 둔
# 가짜 `curl` 이 GitHub API 대신 설치 · 토큰을 돌려주고 받은 인자를 적어 둔다. `HOME` 을 임시
# 디렉터리로 바꿔 개인키의 기본 자리(`~/.config/<App 이름>/key.pem`)를 그대로 지나가게 한다.
# 토큰 글자(`ghs_stubtoken`)가 훅의 출력에 나오면 실패다 — 훅의 출력은 모델의 맥락에 들어간다.
set -u
# 봇에 연결된 세션에서 이 테스트를 실행해도 그 세션의 git 설정이 섞이지 않게 한다
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
KIT="$(cd "$(dirname "$0")/.." && pwd)"
H="$KIT/claude-code/hooks"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/.config/kit-bot"
openssl genrsa -out "$T/home/.config/kit-bot/key.pem" 2048 2>/dev/null
chmod 600 "$T/home/.config/kit-bot/key.pem"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
url = next(x for x in a if x.startswith('https://'))
with open(os.environ['STUB_CURL_LOG'], 'a') as fh:
    fh.write(' '.join(a) + '\n')
if os.environ.get('STUB_CURL_EXIT'):          # 네트워크가 멈춰 curl 이 기다리다 끝난 것(28)
    sys.exit(int(os.environ['STUB_CURL_EXIT']))
auth = ''
for i, x in enumerate(a):
    if x == '-H' and a[i + 1].startswith('@'):
        auth = open(a[i + 1][1:]).read()
if 'Bearer ' not in auth:
    body, code = {'message': 'no jwt'}, 401
elif url.endswith('/installation'):
    code = int(os.environ.get('STUB_INSTALL', '200'))
    body = {'id': 7} if code == 200 else {'message': 'Not Found'}
elif url.endswith('/app/installations/7/access_tokens'):
    code = 201
    body = {'token': 'ghs_stubtoken', 'expires_at': os.environ.get('STUB_EXPIRES', '2099-01-01T00:00:00Z')}
else:
    body, code = {'message': 'stub: 모르는 URL'}, 500
sys.stdout.write(json.dumps(body))
if '-w' in a:
    sys.stdout.write('\n%d' % code)
EOF
chmod +x "$T/bin/curl"
# git 의 자격 증명 도우미로 불릴 가짜 gh. 세션 환경에서 git 이 봇(gh)에게 자격 증명을 받는지 본다.
# 막기 훅이 auto-merge 를 판정하려고 부르는 `gh pr view` · `gh pr list` 에는 STUB_PR_VIEW · STUB_PR_LIST 를
# 돌려준다. STUB_GH_FAIL 이 있으면 그 조회가 실패하고, STUB_GH_LOG 가 있으면 받은 인자를, STUB_GH_ENV 가 있으면
# 받은 GH_CONFIG_DIR 을 적는다. STUB_GH_SLEEP 이 있으면 `gh pr …` 가 그 초만큼 멈춘다(네트워크가 멈춘 것).
# 세션 시작 훅이 부르는 `gh pr list --state merged` 에는 STUB_PR_MERGED 를 돌려준다.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "auth git-credential get" ]; then
  printf 'username=x-access-token\npassword=from-gh-bot\n'
  exit 0
fi
[ -n "${STUB_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_GH_LOG"
[ -n "${STUB_GH_ENV:-}" ] && printf '%s\n' "${GH_CONFIG_DIR:-}" >> "$STUB_GH_ENV"
[ -n "${STUB_GH_SLEEP:-}" ] && [ "$1" = pr ] && exec sleep "$STUB_GH_SLEEP"
[ -n "${STUB_GH_FAIL:-}" ] && { echo 'stub: 조회 실패' >&2; exit 1; }
need='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED"}'
case "$1 $2" in
  "pr view") printf '%s\n' "${STUB_PR_VIEW:-$need}"; exit 0 ;;
  "pr list")
    case " $* " in
      *" merged "*) printf '%s\n' "${STUB_PR_MERGED:-[]}" ;;
      *) printf '%s\n' "${STUB_PR_LIST:-[]}" ;;
    esac
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/bin/gh"
# 사람의 git 설정: osxkeychain 처럼 사람 자격 증명을 주는 도우미가 github.com 에 설정돼 있다
mkdir -p "$T/person"
printf '[credential]\n\thelper = "!f() { echo username=person; echo password=from-person-helper; }; f"\n' \
  > "$T/person/.gitconfig"
fail=0

# 새 레포: 봇 설정 · GitHub origin 을 둔다. repo <디렉터리> [origin URL] [봇 설정 없음이면 no]
repo() {
  rm -rf "$1"; mkdir -p "$1/.claude"; git -C "$1" init -q
  git -C "$1" remote add origin "${2:-https://github.com/o/r.git}"
  [ "${3:-}" = no ] || printf '{"app_id": 1, "app": "kit-bot"}\n' > "$1/.claude/bot.json"
}
R="$T/r"
BOTDIR="$R/.git/ai-kit-bot"

# session <이름> <디렉터리> [CLAUDE_ENV_FILE 을 줄지: yes|no] — SessionStart 훅을 부르고 출력을 $OUT 에 둔다
session() {
  local dir=$2 give=${3:-yes}
  : > "$T/env"; : > "$T/curl-log"
  OUT=$(cd "$dir" && printf '{"session_id": "s1", "cwd": "%s", "hook_event_name": "SessionStart", "source": "startup"}' "$dir" \
    | if [ "$give" = yes ]; then CLAUDE_ENV_FILE="$T/env" HOME="$T/home" PATH="$T/bin:$PATH" \
        STUB_CURL_LOG="$T/curl-log" bash "$H/bot_session.sh"
      else env -u CLAUDE_ENV_FILE HOME="$T/home" PATH="$T/bin:$PATH" \
        STUB_CURL_LOG="$T/curl-log" bash "$H/bot_session.sh"; fi 2>&1)
}
# guard <이름> <pass|deny> <명령> [디렉터리] [사유에 들어 있어야 할 글자]
guard() {
  local name=$1 want=$2 cmd=$3 dir=${4:-$R} must=${5:-} input out got
  input=$(python3 -c 'import json,sys; print(json.dumps({"session_id": "s1", "cwd": sys.argv[1],
    "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$dir" "$cmd")
  : > "$T/curl-log"
  out=$(printf '%s' "$input" | HOME="$T/home" PATH="$T/bin:$PATH" STUB_CURL_LOG="$T/curl-log" \
    bash "$H/bot_guard.sh" 2>&1)
  case "$out" in
    *'"permissionDecision": "deny"'*) got=deny ;;
    *'"permissionDecision": "ask"'*) got=ask ;;
    '') got=pass ;;
    *) got="?:$out" ;;
  esac
  if [ "$got" != "$want" ]; then echo "  ✗ 막기: ${name} — 기대 ${want}, 실제 ${got}"; fail=1; return; fi
  if [ -n "$must" ] && ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ 막기: ${name} — 사유에 「${must}」가 없다: ${out}"; fail=1; return; fi
  if printf '%s' "$out" | grep -qF ghs_stubtoken; then echo "  ✗ 막기: ${name} — 출력에 토큰이 있다"; fail=1; return; fi
  echo "  ✓ 막기: ${name} (${got})"
}
ok() { if eval "$2" 2>/dev/null; then echo "  ✓ $1"; else echo "  ✗ $1"; fail=1; fi; }
no_token_in_out() { ok "$1 — 출력에 토큰이 없다" '! printf "%s" "$OUT" | grep -qF ghs_stubtoken'; }

echo "── 세션 시작(bot_session.sh)"
repo "$R"
session "연결" "$R"
# macOS 의 git 은 임시 디렉터리의 `/var` 를 `/private/var` 로 풀어 적으므로 글자가 아니라 같은
# 디렉터리인지 본다.
ok "GH_CONFIG_DIR 을 CLAUDE_ENV_FILE 에 적는다" '[ "$(sed -n "s/^export GH_CONFIG_DIR=//p" "$T/env")" -ef "$BOTDIR" ]'
ok "봇 계정 이름으로 hosts.yml 을 쓴다" 'grep -qF "\"kit-bot[bot]\"" "$BOTDIR/hosts.yml" && grep -qF ghs_stubtoken "$BOTDIR/hosts.yml"'
ok "gh 가 옮기기(migration)를 안 하게 config.yml 에 version 을 쓴다" 'grep -qF "version: \"1\"" "$BOTDIR/config.yml"'
mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
ok "hosts.yml 은 본인만 읽는다(600)" '[ "$(mode "$BOTDIR/hosts.yml")" = 0o600 ]'
ok "봇 디렉터리는 본인만 연다(700)" '[ "$(mode "$BOTDIR")" = 0o700 ]'
ok "이 세션을 연결했다고 적는다" '[ -f "$BOTDIR/wired/s1" ]'
ok "JWT 파일을 남기지 않는다" '! grep -rqF Bearer "$BOTDIR"'
ok "레포의 설치를 찾고 토큰을 받는다" 'grep -qF "repos/o/r/installation" "$T/curl-log" && grep -qF "installations/7/access_tokens" "$T/curl-log"'
no_token_in_out "연결"
# 세션 환경(CLAUDE_ENV_FILE)을 적용한 git 이 github.com 자격 증명을 봇(gh)에게서만 받고,
# SSH origin 도 https 로 바꿔 쓰는가. 사람의 설정에 자격 증명 도우미가 있어도 그렇다.
in_session() { ( set -a; . "$T/env"; set +a; HOME="$T/person" GIT_CONFIG_NOSYSTEM=1 PATH="$T/bin:$PATH" \
  GIT_TERMINAL_PROMPT=0 "$@" ); }
cred=$(printf 'protocol=https\nhost=github.com\n\n' | in_session git credential fill 2>&1)
ok "세션의 git 은 github.com 자격 증명을 봇(gh)에게서 받는다" 'printf "%s" "$cred" | grep -qx password=from-gh-bot'
ok "세션의 git 은 사람의 자격 증명 도우미를 부르지 않는다" '! printf "%s" "$cred" | grep -qF from-person-helper'
ok "세션의 git 은 SSH origin 을 https 로 바꿔 쓴다" '[ "$(in_session git ls-remote --get-url git@github.com:o/r.git)" = https://github.com/o/r.git ]'
ok "세션의 git 은 ssh:// 주소도 https 로 바꿔 쓴다" '[ "$(in_session git ls-remote --get-url ssh://git@github.com/o/r.git)" = https://github.com/o/r.git ]'
ok "세션 밖의 git 은 사람의 도우미를 그대로 쓴다" 'printf "protocol=https\nhost=github.com\n\n" | HOME="$T/person" GIT_CONFIG_NOSYSTEM=1 git credential fill 2>&1 | grep -qx password=from-person-helper'

# 같은 세션을 다시 시작했는데 토큰을 못 받으면, 앞선 시작이 만든 표시가 남아 있으면 안 된다.
mv "$T/home/.config/kit-bot/key.pem" "$T/key.bak"
session "다시 시작, 개인키 없음" "$R"
mv "$T/key.bak" "$T/home/.config/kit-bot/key.pem"
ok "다시 시작할 때 토큰을 못 받으면 앞선 연결 표시를 지운다" '[ ! -f "$BOTDIR/wired/s1" ]'

# 세션 시작 때 auto-merge 가 켜진 열린 PR 과, 머지됐는데 로컬 브랜치가 남은 PR 을 알린다
ok "알릴 PR 이 없으면 목록을 출력하지 않는다" '! printf "%s" "$OUT" | grep -qF "열린 PR:" && ! printf "%s" "$OUT" | grep -qF "남은 PR:"'
# 알리는 것은 이 clone 의 작업인 PR 이다 — fork 가 아니고, 로컬 브랜치가 있고 그 SHA 가 PR 의 head 와 같고, 다른
# 워크트리에서 쓰지 않는 브랜치다. 동료 · 다른 세션의 PR, fork 의 main 에서 온 PR, 이름만 같은 브랜치는 뺀다.
git -C "$R" commit -q --allow-empty -m init
SHA=$(git -C "$R" rev-parse HEAD); MAIN=$(git -C "$R" symbolic-ref --short HEAD); OTHER=$(printf '1%.0s' {1..40})
for b in feat/a feat/c feat/d feat/e; do git -C "$R" branch "$b"; done
git -C "$R" worktree add -q "$T/wt" feat/d
: > "$T/gh-env"
STUB_GH_ENV="$T/gh-env" STUB_PR_LIST='[{"number": 5, "headRefName": "feat/a", "headRefOid": "'$SHA'", "isCrossRepository": false, "reviewDecision": "APPROVED", "mergeStateStatus": "BEHIND", "autoMergeRequest": {"mergeMethod": "SQUASH"}},
 {"number": 6, "headRefName": "feat/a", "headRefOid": "'$SHA'", "isCrossRepository": false, "reviewDecision": "", "mergeStateStatus": "CLEAN", "autoMergeRequest": null},
 {"number": 7, "headRefName": "feat/teammate", "headRefOid": "'$SHA'", "isCrossRepository": false, "reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}},
 {"number": 8, "headRefName": "feat/c", "headRefOid": "'$SHA'", "isCrossRepository": true, "reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BLOCKED", "autoMergeRequest": {"mergeMethod": "SQUASH"}}]' \
STUB_PR_MERGED='[{"number": 4, "headRefName": "feat/c", "headRefOid": "'$SHA'", "isCrossRepository": false},
 {"number": 3, "headRefName": "feat/gone", "headRefOid": "'$SHA'", "isCrossRepository": false},
 {"number": 2, "headRefName": "feat/d", "headRefOid": "'$SHA'", "isCrossRepository": false},
 {"number": 9, "headRefName": "'$MAIN'", "headRefOid": "'$SHA'", "isCrossRepository": true},
 {"number": 10, "headRefName": "feat/e", "headRefOid": "'$OTHER'", "isCrossRepository": false}]' \
  session "알릴 PR 이 있음" "$R"
ok "auto-merge 가 켜진 열린 PR 과 그 상태를 알린다" 'printf "%s" "$OUT" | grep -qF "#5(feat/a, APPROVED, BEHIND)"'
ok "그 PR 마다 대기 스크립트를 실행하라고 알린다" 'printf "%s" "$OUT" | grep -qF "wait_merge.sh 5"'
ok "auto-merge 가 꺼진 열린 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#6("'
ok "로컬 브랜치가 없는 열린 PR(동료 · 다른 clone 의 작업)은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#7("'
ok "fork 에서 온 열린 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#8("'
ok "머지됐는데 로컬 브랜치가 남은 PR 을 알린다" 'printf "%s" "$OUT" | grep -qF "#4(feat/c)" && printf "%s" "$OUT" | grep -qF "merge-pr 4"'
ok "로컬 브랜치가 없는 머지된 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#3("'
ok "다른 워크트리에서 쓰는 브랜치의 머지된 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#2("'
ok "fork 의 기본 브랜치에서 온 머지된 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#9("'
ok "이름만 같고 SHA 가 다른 로컬 브랜치의 머지된 PR 은 알리지 않는다" '! printf "%s" "$OUT" | grep -qF "#10("'
no_token_in_out "알릴 PR 이 있음"
ok "PR 목록은 봇 계정으로 조회한다" '[ "$(wc -l < "$T/gh-env")" -ge 2 ] && ( while read -r d; do [ "$d" -ef "$BOTDIR" ] || exit 1; done < "$T/gh-env" )'
STUB_GH_FAIL=1 session "PR 조회 실패" "$R"
ok "PR 을 조회하지 못하면 그렇다고 알린다" 'printf "%s" "$OUT" | grep -qF "조회하지 못했다" && [ -f "$BOTDIR/wired/s1" ]'
# 네트워크가 멈춰도 훅의 timeout 전에 끝나야 이미 출력한 연결 안내가 세션에 들어간다
t0=$(date +%s)
BOT_SESSION_GH_TIMEOUT=1 STUB_GH_SLEEP=8 session "PR 조회가 멈춤" "$R"
ok "PR 조회가 멈추면 시간 제한에서 그만두고 그렇다고 알린다" '[ $(( $(date +%s) - t0 )) -lt 8 ] && printf "%s" "$OUT" | grep -qF "조회하지 못했다" && printf "%s" "$OUT" | grep -qF "봇 계정으로 GitHub 에 쓴다"'
git -C "$R" worktree remove --force "$T/wt"

repo "$R" "" no
session "봇 설정 없음" "$R"
ok "봇 설정이 없으면 아무것도 안 한다" '[ ! -s "$T/env" ] && [ ! -s "$T/curl-log" ] && [ -z "$OUT" ]'

repo "$R"
mv "$T/home/.config/kit-bot/key.pem" "$T/key.bak"
session "개인키 없음" "$R"
mv "$T/key.bak" "$T/home/.config/kit-bot/key.pem"
ok "개인키가 없으면 그 자리와 안내 문서를 출력한다" 'printf "%s" "$OUT" | grep -qF "~/.config/kit-bot/key.pem" && printf "%s" "$OUT" | grep -qF kit-guide.md'
ok "개인키가 없으면 연결하지 않는다" '[ ! -s "$T/env" ] && [ ! -f "$BOTDIR/wired/s1" ]'

repo "$R"
STUB_INSTALL=404 session "설치 범위 밖" "$R"
ok "설치에 레포가 없으면 레포 이름과 안내 문서를 출력한다" 'printf "%s" "$OUT" | grep -qF "o/r" && printf "%s" "$OUT" | grep -qF "App 설치" && printf "%s" "$OUT" | grep -qF kit-guide.md'
ok "설치에 레포가 없으면 연결하지 않는다" '[ ! -s "$T/env" ] && [ ! -f "$BOTDIR/wired/s1" ]'

repo "$R" "https://gitlab.com/o/r.git"
session "GitHub 이 아닌 origin" "$R"
ok "GitHub 이 아닌 origin 이면 안내한다" 'printf "%s" "$OUT" | grep -qF kit-guide.md && [ ! -s "$T/env" ]'

repo "$R" "git@github.com:o/r.git"
session "ssh origin" "$R"
ok "ssh 로 적은 origin 에서도 레포를 찾는다" 'grep -qF "repos/o/r/installation" "$T/curl-log" && [ -s "$T/env" ]'

repo "$R"
session "CLAUDE_ENV_FILE 없음" "$R" no
ok "CLAUDE_ENV_FILE 이 없으면 연결하지 못했다고 알린다" 'printf "%s" "$OUT" | grep -qF CLAUDE_ENV_FILE && [ ! -f "$BOTDIR/wired/s1" ]'
no_token_in_out "CLAUDE_ENV_FILE 없음"

echo "── gh 명령 막기(bot_guard.sh)"
repo "$R" "" no
guard "봇 설정이 없으면 막지 않는다" pass "gh pr comment 1 --body-file /tmp/x.md"
guard "봇 설정이 없으면 사람 계정 게시에도 묻지 않는다" pass "bash $H/human_comment.sh 1 /tmp/x.md $(printf '0%.0s' $(seq 64))"

repo "$R"
guard "연결 전의 게시" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "연결"
guard "연결 전의 이슈 열기" deny "gh issue create --title t --body-file /tmp/x.md"
guard "연결 전의 REST 쓰기(-f)" deny "gh api repos/o/r/issues/1/comments -f body=x"
guard "연결 전의 GraphQL 쓰기" deny "gh api graphql -f query='mutation { closeIssue(input: {issueId: \"x\"}) { clientMutationId } }'"
guard "연결 전의 REST 삭제(-X DELETE, 필드 없음)" deny "gh api -X DELETE repos/o/r/issues/comments/1"
guard "연결 전의 GET(필드를 줌)" pass "gh api -X GET search/issues -f q=repo:o/r"
guard "연결 전의 읽기" pass "gh pr diff 1"
guard "연결 전의 도움말(--help)" pass "gh issue create --help"
guard "연결 전의 도움말(-h)" pass "gh pr comment -h"
guard "연결 전 사유의 안내 절 이름" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "「봇 계정과 사람의 승인」 절에 있다"
guard "연결 전의 GraphQL 읽기" pass "gh api graphql -f query='query { viewer { login } }'"
guard "연결 전의 git push" deny "git push -u origin HEAD" "$R" "연결"
guard "연결 전의 git fetch" pass "git fetch origin"
guard "연결 전의 REST 삭제(-XDELETE 붙여 씀)" deny "gh api -XDELETE repos/o/r/issues/comments/1"
guard "연결 전의 GET(-XGET 붙여 씀)" pass "gh api -XGET repos/o/r"
guard "연결 전의 목록 밖 쓰기(pr update-branch)" deny "gh pr update-branch 1"
guard "연결 전의 목록 밖 쓰기(run rerun)" deny "gh run rerun 1"
guard "연결 전의 목록 밖 쓰기(label create)" deny "gh label create x"
guard "연결 전 하위 명령 앞의 플래그(pr -R o/r merge)" deny "gh pr -R o/r merge 1"
guard "연결 전 하위 명령 앞의 플래그 읽기(pr -R o/r view)" pass "gh pr -R o/r view 1"
guard "연결 전의 읽기(run view)" pass "gh run view 1"
guard "연결 전의 읽기(search)" pass "gh search issues x"
guard "연결 전의 읽기(repo view)" pass "gh repo view o/r"
guard "연결 전 명령 치환 안의 머지" deny "x=\$(gh pr merge 1 --squash)"
guard "연결 전 명령 치환 안의 PR 만들기" deny "url=\$(gh pr create --title t --body-file b.md)"
guard "연결 전 큰따옴표 안 명령 치환의 게시" deny "echo \"\$(gh pr comment 1 --body-file b.md)\""
guard "연결 전 백틱 안의 머지" deny "echo \`gh pr merge 1\`"
guard "연결 전 명령 치환 안의 git push" deny "out=\$(git push 2>&1)"
guard "연결 전 인자로 나온 gh" pass "grep -n gh notes.md"
guard "연결 전의 읽기(pr checkout)" pass "gh pr checkout 12"
guard "연결 전 목록 밖 이름의 gh(alias · 확장)" deny "gh pm 1"
guard "연결 전 목록 밖 이름의 gh(새 명령)" deny "gh newcmd create x"
guard "연결 전 래퍼 뒤 목록 밖 이름의 gh" deny "timeout 30 gh pm 1"
guard "연결 전 heredoc 커밋 메시지 안의 git push" pass "git commit -m \"\$(cat <<'EOF'
docs: explain why git push is blocked
EOF
)\""
# 끝 줄이 없는 heredoc 은 본문이 아니다. 그 뒤 줄을 판정에서 빼면 안 된다.
guard "연결 전 끝 줄 없는 heredoc 뒤의 git push" deny "cat <<EOF
git push"
guard "연결 전 따옴표 안의 <<EOF 뒤 줄의 git push" deny "echo \"use <<EOF here\"
git push origin HEAD"
guard "연결 전 heredoc 에 적은 GraphQL mutation" deny "gh api graphql -f query=\"\$(cat <<'EOF'
mutation { closeIssue(input: {issueId: \"x\"}) { clientMutationId } }
EOF
)\""
guard "연결 전 리다이렉션 뒤의 git push" deny "git push >/tmp/push.log 2>&1"

session "연결" "$R"
guard "연결 뒤의 게시" pass "gh pr comment 1 --body-file /tmp/x.md"
ok "토큰이 넉넉하면 새로 받지 않는다" '[ ! -s "$T/curl-log" ]'
guard "연결 뒤의 머지" pass "gh pr merge 1 --squash --subject s --body b"
guard "gh 가 아닌 명령" pass "ls -la high"
guard "연결 뒤의 git push" pass "git push -u origin HEAD"
guard "연결 뒤 heredoc 커밋 메시지 안의 gh auth" pass "git commit -m \"\$(cat <<'EOF'
fix: block gh auth status in the guard
EOF
)\""
# 사람 설정이 없으면 URL 로 준 푸시도 https 로 나간다. 막는 사유는 「주소를 풀지 못해」와 「SSH 주소라서」로
# 다르다 — 아래 SSH 푸시 테스트는 뒤의 것을 본다.
guard "사람 설정 없는 URL 푸시" pass "git push https://github.com/o/r.git HEAD"
# 사람의 git 설정이 github.com 의 https 를 SSH 로 바꾸면 세션의 푸시가 SSH 키로, 곧 사람 계정으로 나간다
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$T/home/.gitconfig"
guard "사람 설정이 https 를 SSH 로 바꾼 푸시(insteadOf)" deny "git push -u origin HEAD" "$R" "SSH 주소라서"
printf '[url "git@github.com:"]\n\tpushInsteadOf = https://github.com/\n' > "$T/home/.gitconfig"
guard "사람 설정이 https 를 SSH 로 바꾼 푸시(pushInsteadOf)" deny "git push" "$R" "SSH 주소라서"
# 원격 자리를 리다이렉션이나 플래그의 값으로 읽으면 주소를 못 풀어 지나간다
guard "리다이렉션이 붙은 푸시(2>&1)" deny "git push 2>&1" "$R" "SSH 주소라서"
guard "리다이렉션이 붙은 푸시(>파일)" deny "git push >/tmp/push.log" "$R" "SSH 주소라서"
guard "리다이렉션 뒤 원격 이름" deny "git push 2>/dev/null origin HEAD" "$R" "SSH 주소라서"
guard "값을 받는 플래그 뒤의 원격(-o)" deny "git push -o ci.skip origin HEAD" "$R" "SSH 주소라서"
guard "값을 받는 플래그 뒤의 원격(--push-option)" deny "git push --push-option ci.skip origin HEAD" "$R" "SSH 주소라서"
guard "값을 붙여 쓴 플래그 뒤의 원격(-oci.skip)" deny "git push -oci.skip origin HEAD" "$R" "SSH 주소라서"
guard "원격을 URL 로 준 푸시" deny "git push https://github.com/o/r.git HEAD" "$R" "SSH 주소라서"
# kit-guide 6절이 적은 대로 이 레포에만 소유자까지 적은 더 긴 규칙을 두면, 가장 긴 규칙이 이겨 https 로 나간다
git -C "$R" config url."https://github.com/o/".pushInsteadOf "https://github.com/o/"
guard "이 레포에서 SSH 바꾸기를 끈 푸시(더 긴 규칙)" pass "git push origin HEAD"
git -C "$R" config --unset url."https://github.com/o/".pushInsteadOf
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$T/home/.gitconfig"
guard "원격을 URL 로 준 푸시(insteadOf)" deny "git push https://github.com/o/r.git HEAD" "$R" "SSH 주소라서"
# 사람 계정 레포(p/)만 SSH 로 바꾸는 설정. origin(o/r)은 https 그대로다.
printf '[url "git@github.com:p/"]\n\tpushInsteadOf = https://github.com/p/\n' > "$T/home/.gitconfig"
git -C "$R" remote add mine https://github.com/p/r.git
guard "origin 이 아닌 원격의 푸시" deny "git push mine HEAD" "$R" "SSH 주소라서"
guard "https 그대로인 origin 의 푸시" pass "git push origin HEAD"
guard "원격을 URL 로 준 푸시(p/)" deny "git push https://github.com/p/r.git HEAD" "$R" "SSH 주소라서"
guard "원격을 --repo= 로 준 푸시" deny "git push --repo=https://github.com/p/r.git" "$R" "SSH 주소라서"
guard "원격을 --repo 로 준 푸시(값을 띄어 씀)" deny "git push --repo mine" "$R" "SSH 주소라서"
git -C "$R" config remote.pushDefault mine
guard "remote.pushDefault 로 고른 원격의 푸시" deny "git push" "$R" "SSH 주소라서"
git -C "$R" config --unset remote.pushDefault
git -C "$R" symbolic-ref HEAD refs/heads/work
git -C "$R" config branch.work.pushRemote mine
guard "branch.<이름>.pushRemote 로 고른 원격의 푸시" deny "git push" "$R" "SSH 주소라서"
git -C "$R" config --unset branch.work.pushRemote
git -C "$R" config branch.work.remote mine
guard "branch.<이름>.remote 로 고른 원격의 푸시" deny "git push" "$R" "SSH 주소라서"
git -C "$R" config --unset branch.work.remote
guard "git -c 로 SSH 로 바꾼 푸시" deny "git -c url.git@github.com:.pushInsteadOf=https://github.com/ push origin HEAD" "$R" "SSH 주소라서"
repo "$T/o2" "https://github.com/p/r.git" no
guard "git -C 로 다른 레포에서 한 푸시" deny "git -C $T/o2 push" "$R" "SSH 주소라서"
guard "git -C 로 다른 레포에서 한 푸시(cd 없이 원격 이름)" deny "git -C $T/o2 push origin HEAD" "$R" "SSH 주소라서"
guard "주소를 풀지 못한 푸시" deny "git -C $T/nope push" "$R" "풀지 못"
git -C "$R" remote remove mine
rm -f "$T/home/.gitconfig"
git -C "$R" remote set-url origin git@github.com:o/r.git
guard "SSH origin 의 푸시(세션이 https 로 바꿔 쓴다)" pass "git push origin HEAD"
git -C "$R" remote set-url origin https://github.com/o/r.git

echo "── auto-merge"
# gh 는 바로 머지할 수 있는 PR(CLEAN · HAS_HOOKS · UNSTABLE)에서 --auto 를 무시하고 그 자리에서 머지한다
# (gh v2.92.0 pkg/cmd/pr/merge/merge.go 의 isImmediatelyMergeable). 승인이 모자라 막힌 PR 에서만 켠다.
NEED='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED"}'
AUTO="gh pr merge 5 --auto --squash --match-head-commit abc --subject s --body b"
STUB_PR_VIEW=$NEED guard "승인이 모자라 막힌 PR 에 auto-merge" pass "$AUTO"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN"}' guard "바로 머지할 수 있는 PR 에 auto-merge" deny "$AUTO" "$R" "바로 머지"
STUB_PR_VIEW='{"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}' guard "이미 승인된 PR 에 auto-merge" deny "$AUTO"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNSTABLE"}' guard "검사가 실패했지만 머지할 수 있는 PR 에 auto-merge" deny "$AUTO"
# 승인을 요구하지 않는 레포에서는 검사가 끝나 BLOCKED 가 풀리면 Approve 없이 머지된다
STUB_PR_VIEW='{"reviewDecision":null,"mergeStateStatus":"BLOCKED"}' guard "승인을 요구하지 않는 레포의 auto-merge" deny "$AUTO" "$R" "승인"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNKNOWN"}' guard "상태를 아직 모르는 PR 에 auto-merge" deny "$AUTO"
STUB_GH_FAIL=1 guard "PR 을 조회하지 못한 auto-merge" deny "$AUTO" "$R" "조회"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN"}' guard "명령 치환 안의 auto-merge" deny "x=\$($AUTO)"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN"}' guard "값을 붙여 쓴 --auto=true" deny "gh pr merge 5 --auto=true --squash"
STUB_PR_VIEW='{"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN"}' guard "auto-merge 끄기(--disable-auto)" pass "gh pr merge 5 --disable-auto"
# 조회는 명령이 가리킨 PR 과 레포로 한다. 값을 받는 플래그의 값을 PR 로 읽으면 다른 PR 을 판정한다.
: > "$T/gh-log"
STUB_GH_LOG="$T/gh-log" STUB_PR_VIEW=$NEED guard "레포와 값 있는 플래그 뒤의 PR" pass "gh pr -R o/r merge --subject 5x --auto 7"
ok "auto-merge 판정은 명령의 PR 과 레포를 조회한다" 'grep -E "^pr view 7( |$)" "$T/gh-log" | grep -qE -- "-R o/r( |$)"'
# 켠 뒤에 푸시하면 사람이 새 커밋을 보고 누른 Approve 가 옛 결정 코멘트대로 머지된다. 먼저 끈다.
ON='[{"number":5,"headRefName":"work","autoMergeRequest":{"enabledAt":"2026-09-28T00:00:00Z"}}]'
OFF='[{"number":5,"headRefName":"work","autoMergeRequest":null}]'
STUB_PR_LIST=$ON guard "auto-merge 가 켜진 PR 의 브랜치에 푸시" deny "git push" "$R" "--disable-auto"
STUB_PR_LIST=$ON guard "auto-merge 가 켜진 브랜치에 HEAD 로 푸시" deny "git push origin HEAD"
STUB_PR_LIST=$ON guard "auto-merge 가 켜진 브랜치 이름으로 푸시" deny "git push -u origin work"
STUB_PR_LIST=$ON guard "다른 브랜치에서 refspec 으로 푸시" deny "git push origin other:refs/heads/work"
# 지금 브랜치(work)가 아닌 브랜치의 PR 에 켜져 있어도, 모든 브랜치를 푸시하면 그 브랜치도 바뀐다
SIDE='[{"number":6,"headRefName":"side","autoMergeRequest":{"enabledAt":"2026-09-28T00:00:00Z"}}]'
STUB_PR_LIST=$SIDE guard "지금 브랜치가 아닌 브랜치에 켜진 채 지금 브랜치 푸시" pass "git push origin HEAD"
STUB_PR_LIST=$SIDE guard "모든 브랜치 푸시(--all)" deny "git push --all origin"
STUB_PR_LIST=$SIDE guard "모든 브랜치 푸시(--mirror)" deny "git push --mirror origin"
STUB_PR_LIST=$ON guard "auto-merge 가 켜지지 않은 브랜치에 푸시" pass "git push origin other"
STUB_PR_LIST=$OFF guard "auto-merge 가 꺼진 PR 의 브랜치에 푸시" pass "git push"
STUB_GH_FAIL=1 guard "PR 목록을 조회하지 못한 푸시" deny "git push" "$R" "조회"
: > "$T/gh-log"
STUB_GH_LOG="$T/gh-log" guard "PR 이 없는 브랜치에 푸시" pass "git push origin HEAD"
ok "푸시 판정은 푸시가 나갈 레포의 PR 을 조회한다" 'grep -E "^pr list( |$)" "$T/gh-log" | grep -qE -- "-R o/r( |$)"'

echo "── 사람 계정으로 올리는 명령(human_comment.sh)"
# 사람이 권한 프롬프트에서 글 전문을 읽고 허락해야 올라간다. 스크립트 경로는 훅과 같은 디렉터리의 것이다.
P="$H/human_comment.sh"
printf '### 4라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "이 PR 에서 만든다"\n  → 새 설계를 만든다\n' > "$T/decision.md"
SUM=$(shasum -a 256 "$T/decision.md" | cut -d' ' -f1)
ZERO=$(printf '0%.0s' $(seq 64))
guard "사람 계정 게시는 글 전문을 보이고 묻는다" ask "bash $P 155 $T/decision.md $SUM" "$R" "이 PR 에서 만든다"
guard "사람 계정 게시 사유의 끝 줄" ask "bash $P 155 $T/decision.md $SUM" "$R" "새 설계를 만든다"
guard "사람 계정 게시(-R)" ask "bash $P 155 $T/decision.md $SUM -R o/r" "$R" "o/r"
guard "sha256 이 다른 사람 계정 게시" deny "bash $P 155 $T/decision.md $ZERO" "$R" "sha256"
guard "다른 명령과 이은 사람 계정 게시" deny "bash $P 155 $T/decision.md $SUM; echo done" "$R" "human_comment.sh"
guard "줄바꿈으로 이은 사람 계정 게시" deny "bash $P 155 $T/decision.md $SUM
echo done"
# 정규형의 낱말 자리에 붙여 쓰면 모양은 맞는다. 셸이 해석하는 글자가 있으면 막는다.
guard "레포 자리에 붙여 이은 사람 계정 게시" deny "bash $P 155 $T/decision.md $SUM -R o/r;id"
guard "레포 자리의 명령 치환" deny "bash $P 155 $T/decision.md $SUM -R \$(id)"
guard "상대 경로 본문의 사람 계정 게시" deny "bash $P 155 decision.md $SUM"
guard "없는 파일의 사람 계정 게시" deny "bash $P 155 $T/nofile.md $SUM"
guard "bash 없이 부른 사람 계정 게시" deny "$P 155 $T/decision.md $SUM"
guard "명령 치환 안의 사람 계정 게시" deny "x=\$(bash $P 155 $T/decision.md $SUM)"
# 셸의 -c 인자 안은 조각으로 나누지 않는다. 그 안의 사람 계정 게시는 권한 프롬프트 없이 실행된다.
guard "bash -c 안의 사람 계정 게시" deny "bash -c 'bash $P 155 $T/decision.md $SUM'" "$R" "human_comment.sh"
guard "sh -c 안의 사람 계정 게시" deny "sh -c \"bash $P 155 $T/decision.md $SUM\""
guard "bash -lc 안의 사람 계정 게시" deny "bash -lc 'bash $P 155 $T/decision.md $SUM'"
mkdir -p "$T/elsewhere"; cp "$P" "$T/elsewhere/human_comment.sh"
guard "훅 디렉터리 밖의 같은 이름 스크립트" deny "bash $T/elsewhere/human_comment.sh 155 $T/decision.md $SUM"
guard "환경을 비우고 부른 gh(env -i)" deny "env -i PATH=/usr/bin gh pr comment 1 --body-file /tmp/x.md" "$R" "env -i"
guard "환경을 비우고 부른 스크립트(env --ignore-environment)" deny "env --ignore-environment bash /tmp/post.sh"
guard "환경을 비우는 env -(대시 하나)" deny "env - HOME=/tmp gh api user"
guard "환경을 비우지 않는 env" pass "env LC_ALL=C sort notes.txt"
# 이름만 나오는 명령(스테이징 · 구문 검사 · 읽기)은 게시가 아니다
guard "사람 계정 스크립트를 스테이징" pass "git add claude-code/hooks/human_comment.sh"
guard "사람 계정 스크립트의 구문 검사" pass "bash -n $P"
guard "사람 계정 스크립트를 읽음" pass "sed -n 1,20p $P"

echo "── 신원을 바꾸거나 토큰을 꺼내는 명령"
# 👍 는 더 이상 승인 표시가 아니다. 연결된 세션의 리액션은 다른 쓰기와 같다.
guard "연결된 세션의 리액션" pass "gh api -X POST repos/o/r/issues/comments/1/reactions -f content=+1"
guard "gh 설정을 바꿈" deny "GH_CONFIG_DIR=\$HOME/.config/gh gh pr comment 1 --body-file /tmp/x.md" "$R" "계정"
guard "gh 설정을 지움" deny "env -u GH_CONFIG_DIR gh api repos/o/r/issues/comments/1/reactions"
guard "토큰을 바꿈" deny "GH_TOKEN=x gh pr comment 1 --body-file /tmp/x.md"
guard "GITHUB_TOKEN 으로 바꿈" deny "export GITHUB_TOKEN=x; gh api user"
guard "사람의 토큰을 꺼냄" deny "gh auth token"
guard "계정을 바꿈" deny "gh auth switch -u someone"
# gh 2.92 의 gh auth status 는 토큰을 마지막 `_` 뒤만 가려, `_` 가 여럿인 봇 설치 토큰을 거의 다 출력한다
guard "인증 상태도 막는다" deny "gh auth status"
guard "명령 치환으로 토큰을 꺼냄" deny "echo \$(gh auth token)"
guard "curl 인자 안에서 토큰을 꺼냄" deny "curl -H \"Authorization: token \$(gh auth token)\" https://api.github.com/user"
guard "git 의 자격 증명 설정을 바꿈" deny "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= git push"
guard "git -c 로 자격 증명 도우미를 바꿈" deny "git -c credential.helper= push"
guard "GIT_CONFIG_COUNT 만 바꿈" deny "export GIT_CONFIG_COUNT=0"
guard "gh 설정에서 토큰을 꺼냄" deny "gh config get -h github.com oauth_token"
guard "명령 치환으로 gh 설정의 토큰을 꺼냄" deny "T=\$(gh config get -h github.com oauth_token); echo \${#T}"
# 연결된 세션의 git 은 github.com 자격 증명을 봇(gh)에게서 받으므로, 자격 증명을 묻는 명령은 봇 토큰을 출력한다
guard "git 에게 자격 증명을 물음" deny "printf 'protocol=https\nhost=github.com\n\n' | git credential fill" "$R" "토큰"
guard "자격 증명 도우미를 직접 부름" deny "git credential-osxkeychain get"
guard "봇 디렉터리의 hosts.yml 을 읽음" deny "cat .git/ai-kit-bot/hosts.yml" "$R" "토큰"
guard "봇 디렉터리로 옮겨 hosts.yml 을 읽음" deny "cd .git/ai-kit-bot && grep token hosts.yml"
# git 디렉터리를 작업 트리 밖에 둔 레포(`--separate-git-dir`)에서는 봇 디렉터리의 경로에 git 이 없다
guard "git 이 없는 경로의 hosts.yml 을 읽음" deny "cat /srv/repo-meta/ai-kit-bot/hosts.yml"
guard "봇 디렉터리의 만료 시각을 읽음" pass "cat .git/ai-kit-bot/expires"
guard "봇 디렉터리의 세션 환경을 읽음" pass "cat .git/ai-kit-bot/session-env"
# 토큰 파일 이름을 적지 않아도 디렉터리째 읽으면 토큰이 출력된다
guard "봇 디렉터리를 통째로 읽음(*)" deny "cat .git/ai-kit-bot/*" "$R" "토큰"
guard "봇 디렉터리를 통째로 검색" deny "grep -r token .git/ai-kit-bot"
guard "봇 디렉터리의 h* 를 읽음" deny "head -50 .git/ai-kit-bot/h*"
# 토큰이 없는 이름을 거쳐 .. 로 올라가면 토큰 파일에 닿는다
guard "허용한 이름 뒤의 .." deny "cat .git/ai-kit-bot/wired/../hosts.yml" "$R" "토큰"
guard "허용한 디렉터리로 옮긴 뒤의 .." deny "cd .git/ai-kit-bot/wired && cat ../hosts.yml"
# Read 도구는 이 훅(Bash)을 거치지 않는다. 설치되는 settings.json 의 deny 가 막는다.
if python3 - "$KIT/claude-code/settings.json" <<'PY'
import json, sys
deny = json.load(open(sys.argv[1], encoding='utf-8'))['permissions']['deny']
# 파일 시스템 루트 기준(//)이어야 작업 디렉터리 밖(worktree 세션의 원래 레포 .git)도 막는다
sys.exit(0 if any(r.startswith('Read(//') and 'ai-kit-bot' in r for r in deny) else 1)
PY
then echo "  ✓ 설치되는 settings.json 이 봇 디렉터리를 Read 에서 막는다"
else echo "  ✗ 설치되는 settings.json 이 봇 디렉터리를 Read 에서 막지 않는다"; fail=1; fi
guard "토큰을 출력하는 인증 상태(-t)" deny "gh auth status -t"
guard "토큰을 출력하는 인증 상태(--show-token)" deny "gh auth status --show-token"
guard "GH_ENTERPRISE_TOKEN 으로 바꿈" deny "GH_ENTERPRISE_TOKEN=x gh api user"
guard "GH_HOST 로 바꿈" deny "GH_HOST=example.com gh pr view 1"

echo "── 토큰 갱신"
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
guard "끝나 가는 토큰으로 게시" pass "gh pr comment 1 --body-file /tmp/x.md"
ok "끝나 가는 토큰은 새로 받는다" 'grep -qF access_tokens "$T/curl-log" && grep -qF 2099 "$BOTDIR/expires"'
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
STUB_INSTALL=404 guard "갱신 실패 뒤의 게시" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "kit-guide.md"
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
STUB_INSTALL=404 guard "갱신 실패 뒤의 읽기" pass "gh pr diff 1"
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
guard "만료된 토큰으로 git push" pass "git push -u origin HEAD"
ok "git push 앞에서도 토큰을 새로 받는다" 'grep -qF access_tokens "$T/curl-log" && grep -qF 2099 "$BOTDIR/expires"'
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
STUB_CURL_EXIT=28 guard "네트워크가 멈춘 뒤의 게시" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "네트워크"
ok "curl 이 기다리는 시간에 끝이 있다" 'grep -qF -- "--max-time" "$T/curl-log"'
# merge-pr 2절이 부르는 판정 스크립트는 안에서 gh 를 부른다. 명령 글자에 gh 가 없어도 새로 받아야 한다.
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
guard "만료된 토큰으로 판정 스크립트" pass "bash .claude/hooks/human_review.sh approved 1"
ok "판정 스크립트 앞에서도 토큰을 새로 받는다" 'grep -qF access_tokens "$T/curl-log" && grep -qF 2099 "$BOTDIR/expires"'
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
guard "만료된 토큰으로 명령 치환 안의 git push" pass "out=\$(git push 2>&1); echo \"\$out\""
ok "명령 치환 안의 git push 앞에서도 토큰을 새로 받는다" 'grep -qF access_tokens "$T/curl-log" && grep -qF 2099 "$BOTDIR/expires"'

echo "── 동시에 토큰을 새로 받음"
# 병렬 Bash 호출이나 여러 워크트리의 세션이 같은 봇 디렉터리의 토큰을 동시에 새로 받는다.
input=$(python3 -c 'import json,sys; print(json.dumps({"session_id": "s1", "cwd": sys.argv[1],
  "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "gh pr comment 1 --body-file /tmp/x.md"}}))' "$R")
: > "$T/curl-log"; rm -f "$T"/par.*
for n in 1 2 3 4 5; do
  printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
  for k in 1 2 3 4; do
    printf '%s' "$input" | HOME="$T/home" PATH="$T/bin:$PATH" STUB_CURL_LOG="$T/curl-log" \
      bash "$H/bot_guard.sh" > "$T/par.$n.$k" 2>&1 &
  done
  wait
done
ok "동시에 새로 받아도 쓰기가 막히지 않는다" '! grep -lq "\"deny\"" "$T"/par.*'

[ "$fail" = 0 ] && echo "  ✓ 봇 설정이 있으면 세션의 gh 를 봇 계정에 연결하고, 벗어나는 쓰기를 막는다"
exit "$fail"
