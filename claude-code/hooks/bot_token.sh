#!/usr/bin/env bash
# 봇 설정(`.claude/bot.json`)대로 GitHub App 의 설치 토큰을 받아 봇 전용 gh 설정 디렉터리에 둔다.
# 필요: python3 · openssl · curl · git. 레포 안에서 실행한다.
#
#     bash .claude/hooks/bot_token.sh
#
# 성공하면 봇 디렉터리의 경로를 한 줄 출력하고 0 으로 끝낸다. 실패하면 무엇을 어디서 고칠지
# 출력하고 1 로 끝낸다. 세션 시작 훅(`bot_session.sh`)과 gh 명령 막기 훅(`bot_guard.sh`)이 부른다.
#
# **봇 설정.** `{"app_id": <App ID>, "app": "<App 이름>"}`. 커밋한다 — 이 레포를 clone 한 사람
# 모두의 세션이 봇 계정으로 쓰고, 사람의 결정은 사람 계정으로 남는다. 개인키는 커밋하지 않고 머신마다
# `~/.config/<App 이름>/key.pem` 에 둔다.
#
# **봇 디렉터리.** `<git 공통 디렉터리>/kit-bot/`. 커밋되지 않는 자리이고, 워크트리들이 같은
# 곳을 쓴다. 사람의 gh 설정(`~/.config/gh`)은 건드리지 않는다. `hosts.yml` 은 gh 의 여러 계정
# 형식으로 봇 계정 이름(`<App 이름>[bot]`)을 적고, `config.yml` 에 `version: "1"` 을 둔다 — 계정
# 이름이 없으면 gh 가 설정을 옮기려고 계정을 조회하는데, 설치 토큰으로는 그 조회가 안 된다.
# `expires` 에 토큰이 끝나는 시각을 둔다. 설치 토큰은 한 시간이면 끝난다.
#
# **개인키 · JWT · 토큰은 출력하지 않는다.** 이 출력은 모델의 맥락에 들어간다. JWT 는 명령
# 인자에 두지 않고(다른 프로세스가 인자를 볼 수 있다) 본인만 읽는 파일로 curl 에 전달하고 지운다.
set -u
GUIDE='docs/process/kit-guide.md 의 「봇 계정과 사람의 승인」 절'
fail() {
  printf '봇 토큰을 받지 못했다: %s\n무엇을 어디서 고치는지는 %s에 있다.\n' "$1" "$GUIDE"
  exit 1
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "git 레포 안이 아니다."
conf="$root/.claude/bot.json"
[ -f "$conf" ] || fail "봇 설정(.claude/bot.json)이 없다."
read -r app_id app < <(python3 -c 'import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not re.match(r"^[A-Za-z0-9-]+$", str(d.get("app", ""))): sys.exit(1)
print(int(d["app_id"]), d["app"])' "$conf" 2>/dev/null) \
  || fail "봇 설정(.claude/bot.json)을 읽지 못했다. {\"app_id\": <숫자>, \"app\": \"<App 이름>\"} 모양이어야 한다."

key="$HOME/.config/$app/key.pem"
[ -r "$key" ] || fail "개인키가 없다: ~/.config/$app/key.pem. GitHub 의 App 설정에서 개인키를 만들어 그 자리에 둔다(권한 600)."

url=$(git -C "$root" remote get-url origin 2>/dev/null) || fail "origin 리모트가 없다."
slug=$(printf '%s' "$url" | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p')
slug=${slug%.git}
[ -n "$slug" ] || fail "origin 이 GitHub 레포가 아니다: $url"

gitdir=$(git -C "$root" rev-parse --git-common-dir) || fail "git 디렉터리를 찾지 못했다."
case "$gitdir" in /*) ;; *) gitdir="$root/$gitdir" ;; esac
dir="$gitdir/kit-bot"
umask 077
mkdir -p "$dir/wired" || fail "봇 디렉터리를 만들지 못했다: $dir"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
pld=$(printf '{"iat":%d,"exp":%d,"iss":%d}' $((now - 60)) $((now + 540)) "$app_id" | b64url)
sig=$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$key" -binary 2>/dev/null | b64url)
[ -n "$sig" ] || fail "개인키로 서명하지 못했다: ~/.config/$app/key.pem 이 PEM 개인키인지 본다."
auth=$(mktemp "$dir/.auth.XXXXXX")
trap 'rm -f "$auth"' EXIT
printf 'Authorization: Bearer %s.%s.%s\n' "$hdr" "$pld" "$sig" > "$auth"

# api <URL> [curl 인자…] — 본문 뒤 마지막 줄에 HTTP 상태를 붙여 출력한다.
# 막기 훅이 명령 앞에서 이 스크립트를 부르므로, 네트워크가 멈춰도 한 호출이 20초를 넘지 않게 한다.
api() {
  local u=$1; shift
  curl -sS --max-time 20 -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' -H @"$auth" \
    "$@" "$u" 2>/dev/null
}
res=$(api "https://api.github.com/repos/$slug/installation")
code=${res##*$'\n'}
case "$code" in
  200) ;;
  404) fail "App($app) 설치에 이 레포($slug)가 없다. GitHub 의 App 설치 설정에서 저장소 목록에 이 레포를 더한다." ;;
  401) fail "App ID 와 개인키가 맞지 않다(HTTP 401). .claude/bot.json 의 app_id 와 ~/.config/$app/key.pem 을 본다." ;;
  *) fail "레포의 App 설치를 찾다가 실패했다(HTTP ${code:-없음}). 네트워크를 본다." ;;
esac
iid=$(printf '%s' "${res%$'\n'*}" | python3 -c 'import json, sys; print(int(json.load(sys.stdin)["id"]))' 2>/dev/null) \
  || fail "App 설치 응답을 읽지 못했다."

res=$(api "https://api.github.com/app/installations/$iid/access_tokens" -X POST)
code=${res##*$'\n'}
[ "$code" = 201 ] || fail "설치 토큰을 받지 못했다(HTTP ${code:-없음})."
# 토큰은 명령 인자에 두지 않고 표준입력으로 파이썬에 전달해 파일로만 쓴다.
# 여러 세션 · 병렬 명령이 같은 봇 디렉터리의 토큰을 동시에 새로 받을 수 있다. 임시 파일은 호출마다
# 다른 이름으로 만들고(mkstemp, 권한 600) 제자리로 옮긴다 — 이름이 같으면 한쪽이 상대의 임시 파일을
# 옮겨 버려 다른 쪽이 실패한다.
printf '%s' "${res%$'\n'*}" | python3 -c 'import json, os, sys, tempfile
d, app, where = json.load(sys.stdin), sys.argv[1], sys.argv[2]
tok, until = d["token"], d["expires_at"]
user = "%s[bot]" % app
files = {
    "config.yml": "version: \"1\"\n",
    "hosts.yml": ("github.com:\n    users:\n        \"%s\":\n            oauth_token: %s\n"
                  "    git_protocol: https\n    oauth_token: %s\n    user: \"%s\"\n") % (user, tok, tok, user),
    "expires": until + "\n",
}
for name, text in files.items():
    fd, tmp = tempfile.mkstemp(dir=where, prefix="." + name + ".")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.replace(tmp, os.path.join(where, name))' "$app" "$dir" 2>/dev/null \
  || fail "설치 토큰 응답을 읽지 못했다."
printf '%s\n' "$dir"
