#!/usr/bin/env bash
# SessionStart: 레포에 봇 설정(`.claude/bot.json`)이 있으면 이 세션의 gh 를 봇 계정에 연결한다.
# 필요: python3 · openssl · curl · git
#
# **왜 연결하나.** 봇 설정이 있으면 세션이 GitHub 에 쓰는 글은 봇 계정으로 올라가고, 사람은 자기
# 계정으로 3.5 코멘트에 👍 를 단다. 그래서 GitHub 에서 세션의 글과 사람의 승인이 구분된다.
# 세션이 사람 계정으로 쓰면 그 구분이 사라진다.
#
# **어떻게.** 토큰 스크립트(`bot_token.sh`)로 설치 토큰을 받아 봇 디렉터리에 두고,
# `CLAUDE_ENV_FILE` 에 `export GH_CONFIG_DIR=<봇 디렉터리>` 와, git 이 github.com 자격 증명을
# gh(봇)에게서만 받고 SSH origin 을 https 로 바꿔 쓰게 하는 `GIT_CONFIG_*` 를 적는다. git 이
# 자격 증명을 어디서 받든(osxkeychain · SSH 키) 세션의 푸시가 봇 계정으로 나가게 하려는 것이고,
# 사용자의 git 설정 파일은 건드리지 않는다. Claude Code 는 이 파일을
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
  printf '봇 토큰은 받았지만 CLAUDE_ENV_FILE 이나 session_id 가 없어 이 세션의 gh 를 봇 계정에 연결하지 못했다. GitHub 에 쓰는 gh 명령과 git push 는 막힌다. docs/process/kit-guide.md 의 「봇 계정과 👍 승인」 절을 본다.\n'
  exit 0
fi
# git 도 github.com 자격 증명을 봇(gh)에게서만 받게 하고, SSH origin 도 https 로 바꿔 쓰게 한다.
# 세션 환경 변수로만 바꾼다 — 사용자의 git 설정 파일은 건드리지 않는다. 자격 증명 도우미는 여러 값이
# 쌓이는 목록이라, 빈 값으로 앞의 것(osxkeychain 같은 사람의 도우미)을 비운 뒤 gh 하나만 둔다.
{
  printf 'export GH_CONFIG_DIR=%q\n' "$dir"
  printf 'export GIT_CONFIG_COUNT=4\n'
  printf 'export GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0=\n'
  printf "export GIT_CONFIG_KEY_1=credential.https://github.com.helper GIT_CONFIG_VALUE_1='!gh auth git-credential'\n"
  printf 'export GIT_CONFIG_KEY_2=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_2=git@github.com:\n'
  printf 'export GIT_CONFIG_KEY_3=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_3=ssh://git@github.com/\n'
} >> "$CLAUDE_ENV_FILE"
: > "$dir/wired/$sid"
printf '이 세션의 gh 는 봇 계정으로 GitHub 에 쓴다(GH_CONFIG_DIR=%s). 3.5 코멘트를 올리면 사람에게 그 코멘트에 자기 계정으로 👍 를 달아 달라고 알린다 — 👍 가 있는 3.5 코멘트만 (사람) 인용의 원본으로 인정된다. 세션이 👍 를 달지 않는다.\n' "$dir"
