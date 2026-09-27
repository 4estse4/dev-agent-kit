#!/usr/bin/env bash
# SessionStart: 레포에 봇 설정(`.claude/bot.json`)이 있으면 이 세션의 gh 를 봇 계정에 연결한다.
# 필요: python3 · openssl · curl · git
#
# **왜 연결하나.** 봇 설정이 있으면 세션이 GitHub 에 쓰는 글은 봇 계정으로 올라가고, 사람의 결정은
# 사람 계정의 코멘트와 Approve 로 남는다. 그래서 GitHub 에서 세션의 글과 사람의 승인이 구분된다.
# 세션이 사람 계정으로 쓰면 그 구분이 사라진다.
#
# **어떻게.** 토큰 스크립트(`bot_token.sh`)로 설치 토큰을 받아 봇 디렉터리에 두고,
# `CLAUDE_ENV_FILE` 에 `export GH_CONFIG_DIR=<봇 디렉터리>` 와, git 이 github.com 자격 증명을
# gh(봇)에게서만 받고 github.com 의 SSH 주소를 https 로 바꿔 쓰게 하는 `GIT_CONFIG_*` 를 적는다.
# git 이 자격 증명을 어디서 받든(osxkeychain · SSH 키) 세션의 푸시가 봇 계정으로 나가게 하려는 것이고,
# 사용자의 git 설정 파일은 건드리지 않는다. 사람의 설정이 https 를 다시 SSH 로 바꾸는 경우는 막기 훅이
# 푸시 앞에서 막는다. Claude Code 는 이 파일을
# 이 세션의 뒤따르는 Bash 명령마다 적용한다. 이 변수를 쓸 수 있는 훅은 SessionStart · Setup ·
# CwdChanged · FileChanged 이고, PreToolUse 는 쓰지 못한다. 여기 적은 값은 `cd` 뒤에도 남고
# 서브에이전트의 Bash 에도 적용된다(실제 세션에서 확인했다). 연결했으면
# `<봇 디렉터리>/wired/<session_id>` 를 만든다 — gh 명령 막기 훅(`bot_guard.sh`)은 이 파일이 없는
# 세션의 쓰기를 막는다. 연결되지 않은 세션의 gh 는 사람 계정이라서다.
#
# **시작할 때마다 이 세션의 표시부터 지운다.** 같은 세션을 다시 시작(resume)하면 이 훅이 다시
# 실행된다. 그때 토큰을 못 받으면 이번 시작은 `GH_CONFIG_DIR` 을 적지 않는데, 앞선 시작이 만든
# 표시가 남아 있으면 막기 훅이 이 세션을 연결된 것으로 본다.
#
# **실패하면 연결하지 않고 까닭을 출력한다.** 이 출력은 모델의 맥락에 들어간다. 읽기는 사람
# 계정으로 계속되고, 쓰기는 `bot_guard.sh` 가 막는다.
input=$(cat)
here="$(cd "$(dirname "$0")" && pwd)"
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/.claude/bot.json" ] || exit 0
sid=$(printf '%s' "$input" | python3 -c 'import json, re, sys
s = str(json.load(sys.stdin).get("session_id") or "")
print(s if re.match(r"^[A-Za-z0-9_-]+$", s) else "")' 2>/dev/null)
gitdir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)
case "$gitdir" in /*) ;; *) gitdir="$root/$gitdir" ;; esac
[ -n "$sid" ] && rm -f "$gitdir/ai-kit-bot/wired/$sid"

if ! out=$(bash "$here/bot_token.sh"); then
  printf '%s\n이 세션의 gh 는 봇 계정에 연결되지 않았다. 읽기는 사람 계정으로 되고, GitHub 에 쓰는 gh 명령과 git push 는 막힌다.\n' "$out"
  exit 0
fi
dir=$out
if [ -z "${CLAUDE_ENV_FILE:-}" ] || [ -z "$sid" ]; then
  printf '봇 토큰은 받았지만 CLAUDE_ENV_FILE 이나 session_id 가 없어 이 세션의 gh 를 봇 계정에 연결하지 못했다. GitHub 에 쓰는 gh 명령과 git push 는 막힌다. docs/process/kit-guide.md 의 「봇 계정과 사람의 승인」 절을 본다.\n'
  exit 0
fi
# git 도 github.com 자격 증명을 봇(gh)에게서만 받게 하고, github.com 의 SSH 주소(`git@github.com:` ·
# `ssh://git@github.com/`)도 https 로 바꿔 쓰게 한다. origin 만이 아니라 세션에서 github.com 에 접속하는
# git 명령이 모두 그렇다(서브모듈 · git 의존성 포함) — 그래서 설치 범위 밖의 비공개 레포는 세션에서 fetch · clone 이 안
# 된다. 세션 환경 변수로만 바꾼다 — 사용자의 git 설정 파일은 건드리지 않는다. 자격 증명 도우미는 여러
# 값이 쌓이는 목록이라, 빈 값으로 앞의 것(osxkeychain 같은 사람의 도우미)을 비운 뒤 gh 하나만 둔다.
# 같은 줄을 봇 디렉터리의 `session-env` 에도 둔다 — 막기 훅은 이 파일로 세션의 git 이 실제로 푸시할
# 주소를 풀어 본다(사람의 설정이 https 를 SSH 로 다시 바꾸면 세션의 푸시가 사람 계정으로 나간다).
env_lines=$(
  printf 'export GH_CONFIG_DIR=%q\n' "$dir"
  printf 'export GIT_CONFIG_COUNT=4\n'
  printf 'export GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=\n'
  printf "export GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'\n"
  printf 'export GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_2=git@github.com:\n'
  printf 'export GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_3=ssh://git@github.com/\n'
)
printf '%s\n' "$env_lines" >> "$CLAUDE_ENV_FILE"
printf '%s\n' "$env_lines" > "$dir/session-env"
: > "$dir/wired/$sid"
printf '이 세션의 gh 는 봇 계정으로 GitHub 에 쓴다(GH_CONFIG_DIR=%s). 사람의 결정은 사람 계정 코멘트로 남긴다 — 세션이 받은 답은 human_comment.sh 로 올리고(권한 프롬프트에 글 전문이 보인다), 사람이 PR 웹에서 직접 쓸 수도 있다. 사람 계정 코멘트만 (사람) 인용의 원본이고, 머지는 사람의 Approve 를 확인한 뒤에 한다.\n' "$dir"
