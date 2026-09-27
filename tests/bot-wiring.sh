#!/usr/bin/env bash
# 레포에 봇 설정(`.claude/bot.json`)이 있을 때 세션의 gh 를 봇 계정으로 배선하고, 그 배선을 벗어나는
# 쓰기를 막는가.
#
# 세 훅을 Claude Code 가 부르는 모양으로 부른다 — SessionStart 의 `bot_session.sh` 와 PreToolUse 의
# `bot_guard.sh` 에는 표준입력에 JSON 을 넣고, `CLAUDE_ENV_FILE` 을 준다. 토큰 스크립트
# `bot_token.sh` 는 두 훅이 부르는 것을 지나가게 한다.
#
# **네트워크와 진짜 개인키를 안 쓴다.** 개인키는 이 테스트가 만든 버릴 RSA 키이고, PATH 앞에 둔
# 가짜 `curl` 이 GitHub API 대신 설치 · 토큰을 돌려주고 받은 URL 을 적어 둔다. `HOME` 을 임시
# 디렉터리로 바꿔 개인키의 기본 자리(`~/.config/<App 이름>/key.pem`)를 그대로 지나가게 한다.
# 토큰 글자(`ghs_stubtoken`)가 훅의 출력에 나오면 실패다 — 훅의 출력은 모델의 맥락에 들어간다.
set -u
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
    fh.write(url + '\n')
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
session "배선" "$R"
# macOS 의 git 은 임시 디렉터리의 `/var` 를 `/private/var` 로 풀어 적으므로 글자가 아니라 같은
# 디렉터리인지 본다.
ok "GH_CONFIG_DIR 을 CLAUDE_ENV_FILE 에 적는다" '[ "$(sed -n "s/^export GH_CONFIG_DIR=//p" "$T/env")" -ef "$BOTDIR" ]'
ok "봇 계정 이름으로 hosts.yml 을 쓴다" 'grep -qF "\"kit-bot[bot]\"" "$BOTDIR/hosts.yml" && grep -qF ghs_stubtoken "$BOTDIR/hosts.yml"'
ok "gh 가 옮기기(migration)를 안 하게 config.yml 에 version 을 쓴다" 'grep -qF "version: \"1\"" "$BOTDIR/config.yml"'
mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }
ok "hosts.yml 은 본인만 읽는다(600)" '[ "$(mode "$BOTDIR/hosts.yml")" = 0o600 ]'
ok "봇 디렉터리는 본인만 연다(700)" '[ "$(mode "$BOTDIR")" = 0o700 ]'
ok "이 세션을 배선했다고 적는다" '[ -f "$BOTDIR/wired/s1" ]'
ok "JWT 파일을 남기지 않는다" '! grep -rqF Bearer "$BOTDIR"'
ok "레포의 설치를 찾고 토큰을 받는다" 'grep -qF "repos/o/r/installation" "$T/curl-log" && grep -qF "installations/7/access_tokens" "$T/curl-log"'
no_token_in_out "배선"

repo "$R" "" no
session "봇 설정 없음" "$R"
ok "봇 설정이 없으면 아무것도 안 한다" '[ ! -s "$T/env" ] && [ ! -s "$T/curl-log" ] && [ -z "$OUT" ]'

repo "$R"
mv "$T/home/.config/kit-bot/key.pem" "$T/key.bak"
session "개인키 없음" "$R"
mv "$T/key.bak" "$T/home/.config/kit-bot/key.pem"
ok "개인키가 없으면 그 자리와 안내 문서를 출력한다" 'printf "%s" "$OUT" | grep -qF "~/.config/kit-bot/key.pem" && printf "%s" "$OUT" | grep -qF kit-guide.md'
ok "개인키가 없으면 배선하지 않는다" '[ ! -s "$T/env" ] && [ ! -f "$BOTDIR/wired/s1" ]'

repo "$R"
STUB_INSTALL=404 session "설치 범위 밖" "$R"
ok "설치에 레포가 없으면 레포 이름과 안내 문서를 출력한다" 'printf "%s" "$OUT" | grep -qF "o/r" && printf "%s" "$OUT" | grep -qF "App 설치" && printf "%s" "$OUT" | grep -qF kit-guide.md'
ok "설치에 레포가 없으면 배선하지 않는다" '[ ! -s "$T/env" ] && [ ! -f "$BOTDIR/wired/s1" ]'

repo "$R" "https://gitlab.com/o/r.git"
session "GitHub 이 아닌 origin" "$R"
ok "GitHub 이 아닌 origin 이면 안내한다" 'printf "%s" "$OUT" | grep -qF kit-guide.md && [ ! -s "$T/env" ]'

repo "$R" "git@github.com:o/r.git"
session "ssh origin" "$R"
ok "ssh 로 적은 origin 에서도 레포를 찾는다" 'grep -qF "repos/o/r/installation" "$T/curl-log" && [ -s "$T/env" ]'

repo "$R"
session "CLAUDE_ENV_FILE 없음" "$R" no
ok "CLAUDE_ENV_FILE 이 없으면 배선하지 못했다고 알린다" 'printf "%s" "$OUT" | grep -qF CLAUDE_ENV_FILE && [ ! -f "$BOTDIR/wired/s1" ]'
no_token_in_out "CLAUDE_ENV_FILE 없음"

echo "── gh 명령 막기(bot_guard.sh)"
repo "$R" "" no
guard "봇 설정이 없으면 막지 않는다" pass "gh api -X POST repos/o/r/issues/comments/1/reactions -f content=+1"

repo "$R"
guard "배선 전의 게시" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "배선"
guard "배선 전의 이슈 열기" deny "gh issue create --title t --body-file /tmp/x.md"
guard "배선 전의 REST 쓰기(-f)" deny "gh api repos/o/r/issues/1/comments -f body=x"
guard "배선 전의 GraphQL 쓰기" deny "gh api graphql -f query='mutation { closeIssue(input: {issueId: \"x\"}) { clientMutationId } }'"
guard "배선 전의 REST 삭제(-X DELETE, 필드 없음)" deny "gh api -X DELETE repos/o/r/issues/comments/1"
guard "배선 전의 GET(필드를 줌)" pass "gh api -X GET search/issues -f q=repo:o/r"
guard "배선 전의 읽기" pass "gh pr diff 1"
guard "배선 전의 도움말(--help)" pass "gh issue create --help"
guard "배선 전의 도움말(-h)" pass "gh pr comment -h"
guard "배선 전 사유의 안내 절 이름" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "「봇 계정과 👍 승인」 절에 있다"
guard "배선 전의 GraphQL 읽기" pass "gh api graphql -f query='query { viewer { login } }'"

session "배선" "$R"
guard "배선 뒤의 게시" pass "gh pr comment 1 --body-file /tmp/x.md"
ok "토큰이 넉넉하면 새로 받지 않는다" '[ ! -s "$T/curl-log" ]'
guard "배선 뒤의 머지" pass "gh pr merge 1 --squash --subject s --body b"
guard "gh 가 아닌 명령" pass "ls -la high"

echo "── 스스로 승인하는 명령"
guard "REST 로 👍(-X POST)" deny "gh api -X POST repos/o/r/issues/comments/1/reactions -f content=+1" "$R" "👍"
guard "REST 로 👍(-f 만, 기본 POST)" deny "gh api repos/o/r/issues/comments/1/reactions -f content=+1"
guard "REST 로 👍(--method post)" deny "gh api --method post repos/o/r/issues/comments/1/reactions --raw-field content=+1"
guard "GraphQL 로 👍" deny "gh api graphql -f query='mutation { addReaction(input: {subjectId: \"x\", content: THUMBS_UP}) { clientMutationId } }'"
guard "curl 로 👍" deny "curl -X POST -H \"Authorization: token x\" https://api.github.com/repos/o/r/issues/comments/1/reactions -d '{\"content\":\"+1\"}'"
guard "👍 를 읽기만 함" pass "gh api repos/o/r/issues/comments/1/reactions"
guard "gh 설정을 바꿈" deny "GH_CONFIG_DIR=\$HOME/.config/gh gh pr comment 1 --body-file /tmp/x.md" "$R" "계정"
guard "gh 설정을 지움" deny "env -u GH_CONFIG_DIR gh api repos/o/r/issues/comments/1/reactions"
guard "토큰을 바꿈" deny "GH_TOKEN=x gh pr comment 1 --body-file /tmp/x.md"
guard "GITHUB_TOKEN 으로 바꿈" deny "export GITHUB_TOKEN=x; gh api user"
guard "사람의 토큰을 꺼냄" deny "gh auth token"
guard "계정을 바꿈" deny "gh auth switch -u someone"
guard "인증 상태만 봄" pass "gh auth status"

echo "── 토큰 갱신"
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
guard "끝나 가는 토큰으로 게시" pass "gh pr comment 1 --body-file /tmp/x.md"
ok "끝나 가는 토큰은 새로 받는다" 'grep -qF access_tokens "$T/curl-log" && grep -qF 2099 "$BOTDIR/expires"'
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
STUB_INSTALL=404 guard "갱신 실패 뒤의 게시" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "kit-guide.md"
printf '2000-01-01T00:00:00Z\n' > "$BOTDIR/expires"
STUB_INSTALL=404 guard "갱신 실패 뒤의 읽기" pass "gh pr diff 1"

[ "$fail" = 0 ] && echo "  ✓ 봇 설정이 있으면 세션의 gh 를 봇으로 배선하고, 벗어나는 쓰기를 막는다"
exit "$fail"
