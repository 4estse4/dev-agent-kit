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
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "auth git-credential get" ]; then
  printf 'username=x-access-token\npassword=from-gh-bot\n'
  exit 0
fi
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
ok "세션 밖의 git 은 사람의 도우미를 그대로 쓴다" 'printf "protocol=https\nhost=github.com\n\n" | HOME="$T/person" GIT_CONFIG_NOSYSTEM=1 git credential fill 2>&1 | grep -qx password=from-person-helper'

# 같은 세션을 다시 시작했는데 토큰을 못 받으면, 앞선 시작이 만든 표시가 남아 있으면 안 된다.
mv "$T/home/.config/kit-bot/key.pem" "$T/key.bak"
session "다시 시작, 개인키 없음" "$R"
mv "$T/key.bak" "$T/home/.config/kit-bot/key.pem"
ok "다시 시작할 때 토큰을 못 받으면 앞선 연결 표시를 지운다" '[ ! -f "$BOTDIR/wired/s1" ]'

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
guard "봇 설정이 없으면 막지 않는다" pass "gh api -X POST repos/o/r/issues/comments/1/reactions -f content=+1"

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
guard "연결 전 사유의 안내 절 이름" deny "gh pr comment 1 --body-file /tmp/x.md" "$R" "「봇 계정과 👍 승인」 절에 있다"
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

session "연결" "$R"
guard "연결 뒤의 게시" pass "gh pr comment 1 --body-file /tmp/x.md"
ok "토큰이 넉넉하면 새로 받지 않는다" '[ ! -s "$T/curl-log" ]'
guard "연결 뒤의 머지" pass "gh pr merge 1 --squash --subject s --body b"
guard "gh 가 아닌 명령" pass "ls -la high"
guard "연결 뒤의 git push" pass "git push -u origin HEAD"

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
# gh 2.92 의 gh auth status 는 토큰을 마지막 `_` 뒤만 가려, `_` 가 여럿인 봇 설치 토큰을 거의 다 출력한다
guard "인증 상태도 막는다" deny "gh auth status"
guard "명령 치환으로 토큰을 꺼냄" deny "echo \$(gh auth token)"
guard "curl 인자 안에서 토큰을 꺼냄" deny "curl -H \"Authorization: token \$(gh auth token)\" https://api.github.com/user"
guard "reactions 를 찾는 grep -F" pass "grep -n -F reactions claude-code/hooks/answer_approvals.sh"
guard "reactions 이름의 브랜치 지우기" pass "git branch -d fix-reactions"
guard "reactions 파일 지우기" pass "rm -f /tmp/reactions.json"
guard "git 의 자격 증명 설정을 바꿈" deny "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= git push"
guard "토큰을 출력하는 인증 상태(-t)" deny "gh auth status -t"
guard "토큰을 출력하는 인증 상태(--show-token)" deny "gh auth status --show-token"
guard "GH_ENTERPRISE_TOKEN 으로 바꿈" deny "GH_ENTERPRISE_TOKEN=x gh api user"
guard "GH_HOST 로 바꿈" deny "GH_HOST=example.com gh pr view 1"
guard "👍 를 GraphQL 로 읽기만 함" pass "gh api graphql -f query='query { repository(owner: \"o\", name: \"r\") { pullRequest(number: 1) { comments(first: 5) { nodes { reactions(content: THUMBS_UP, first: 5) { nodes { createdAt } } } } } } }'"

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
