#!/usr/bin/env bash
# PreToolUse(Bash): 레포에 봇 설정(`.claude/bot.json`)이 있을 때, 세션의 gh 가 봇 계정을 벗어나
# GitHub 에 쓰는 것을 막는다. 필요: python3 · git(토큰을 새로 받을 때 openssl · curl)
#
# **무엇을 막나.**
# - 세션이 👍 를 다는 명령. REST 의 `…/reactions` 에 쓰는 호출(`-X`/`--method` 가 GET 이 아니거나,
#   `-f` · `-F` · `--field` · `--raw-field` · `--input` · `-d` · `--data` 를 준 호출)과 GraphQL 의
#   `addReaction`. 👍 는 사람이 3.5 코멘트를 승인하는 표시라서, 세션이 달면 스스로 승인하는 셈이다
# - gh 의 신원을 바꾸는 명령. 명령 글자에 `GH_CONFIG_DIR` · `GH_TOKEN` · `GITHUB_TOKEN` ·
#   `GH_ENTERPRISE_TOKEN` · `GH_HOST` 가 있거나, `gh auth` 의 `status` 가 아닌 하위 명령.
#   사람의 gh 설정이나 토큰으로 바꾸면 세션의 글이 사람의 글로 올라가고 사람의 👍 도 달 수 있다
# - 배선되지 않은 세션의 쓰기. 세션 시작 훅(`bot_session.sh`)이 이 세션을 봇으로 배선하지 못했으면
#   그 세션의 gh 는 사람 계정이다. gh 로 쓰는 명령(`gh pr`/`gh issue` 의 comment · create · merge ·
#   close · reopen · edit · review · ready · lock · unlock · delete · transfer · pin · unpin · develop,
#   쓰는 `gh api`)을 막는다. 읽기는 막지 않는다
# - 봇 토큰이 끝나 가는데 새로 받지 못한 뒤의 쓰기
#
# **토큰을 새로 받는다.** 설치 토큰은 한 시간이면 끝난다. 배선된 세션이 gh 를 부를 때 토큰이
# 10분 안에 끝나면 토큰 스크립트(`bot_token.sh`)로 새로 받아 봇 디렉터리의 파일만 바꾼다.
# `GH_CONFIG_DIR` 은 그대로 그 디렉터리를 가리킨다.
#
# **무엇을 못 막나.** 명령 글자로 알아보므로, 스크립트 파일 안이나 인라인 인터프리터
# (`python3 -c` 등) 안의 호출은 못 본다. 명령 글자에 위 낱말이 있으면 검색이나 커밋 메시지도
# 막힌다 — 그 글자를 파일로 옮겨 전달한다. 이 훅은 형식대로 입력한 명령의 실수를 막고, 작정한
# 우회는 막으려 하지 않는다. 작정한 우회를 막는 것은 CI 와 브랜치 보호다.
input=$(cat)
# 모든 Bash 호출마다 실행되므로 관련 글자가 없으면 파이썬을 실행하지 않고 끝낸다.
case "$input" in
  *gh*|*GH_*|*GITHUB_TOKEN*|*reactions*|*addReaction*) ;;
  *) exit 0 ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" HOOK_INPUT="$input" python3 - <<'PY'
import datetime, json, os, re, subprocess, sys

GUIDE = "docs/process/kit-guide.md 의 「봇 계정과 👍 승인」 절"


def deny(why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''
cwd = data.get('cwd') or None
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd, capture_output=True, text=True)
if top.returncode or not os.path.isfile(os.path.join(top.stdout.strip(), '.claude', 'bot.json')):
    sys.exit(0)

IDENTITY = re.compile(r'\b(GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GH_HOST)\b')
AUTH = re.compile(r'(?<![\w.-])gh\s+auth\s+(?!status\b)\S')
GH = re.compile(r'(?<![\w.-])gh\s')
METHOD = re.compile(r'(?:^|\s)(?:-X|--method|--request)(?:\s+|=)["\']?([A-Za-z]+)')
FIELDS = re.compile(r'(?:^|\s)(?:-f|-F|--field|--raw-field|--input|-d|--data(?:-raw|-binary)?)(?:\s|=)')
WRITE_SUB = re.compile(
    r'(?<![\w.-])gh\s+(?:pr|issue)\s+(?:comment|create|merge|close|reopen|edit|review|ready|lock|'
    r'unlock|delete|transfer|pin|unpin|develop)\b')


def writes(c):
    """REST 는 메서드와 필드로, GraphQL 은 mutation 으로 쓰는 호출인지 가린다."""
    m = METHOD.search(c)
    if m:
        return m.group(1).upper() != 'GET'
    return bool(FIELDS.search(c))


if IDENTITY.search(cmd) or AUTH.search(cmd):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, 세션의 gh 는 봇 계정으로만 쓴다. gh 의 설정 · "
         "토큰 · 계정을 바꾸는 명령(GH_CONFIG_DIR · GH_TOKEN · GITHUB_TOKEN · gh auth)은 막는다 — "
         "사람의 계정으로 바꾸면 세션의 글이 사람의 글로 남고 사람의 👍 도 달 수 있다. 그 낱말이 검색어나 "
         "글이면 파일로 옮겨 전달한다.")
if 'addReaction' in cmd or ('reactions' in cmd and writes(cmd)):
    deny("세션은 👍 를 달지 않는다. 3.5 코멘트의 👍 는 사람이 자기 계정으로 달아 승인하는 표시다. "
         "사람에게 그 코멘트에 👍 를 달아 달라고 알린다.")
if not GH.search(cmd):
    sys.exit(0)

common = subprocess.run(['git', 'rev-parse', '--git-common-dir'], cwd=cwd, capture_output=True,
                        text=True).stdout.strip()
botdir = os.path.join(cwd or os.getcwd(), common, 'ai-kit-bot') if common else ''
sid = str(data.get('session_id') or '')
wired = bool(botdir and re.match(r'^[A-Za-z0-9_-]+$', sid)
             and os.path.isfile(os.path.join(botdir, 'wired', sid)))


def left():
    """봇 토큰이 끝나기까지 남은 초. 모르면 -1."""
    try:
        until = open(os.path.join(botdir, 'expires'), encoding='utf-8').read().strip()
        end = datetime.datetime.strptime(until, '%Y-%m-%dT%H:%M:%SZ').replace(
            tzinfo=datetime.timezone.utc)
    except (OSError, ValueError):
        return -1
    return (end - datetime.datetime.now(datetime.timezone.utc)).total_seconds()


why = ''
if wired and left() < 600:
    r = subprocess.run(['bash', os.path.join(os.environ['HOOK_DIR'], 'bot_token.sh')], cwd=cwd,
                       capture_output=True, text=True, timeout=60)
    if r.returncode:
        why = r.stdout.strip()

# 도움말(`-h` · `--help`)은 무엇도 쓰지 않는다.
cmd_writes = not re.search(r'(?:^|\s)(?:-h|--help)(?=\s|$)', cmd) and (
    bool(WRITE_SUB.search(cmd)) or (bool(re.search(r'(?<![\w.-])gh\s+api\b', cmd)) and (
        'mutation' in cmd if re.search(r'(?<![\w.-])gh\s+api\s+graphql\b', cmd) else writes(cmd))))
if not cmd_writes:
    sys.exit(0)
if not wired:
    deny("이 세션의 gh 는 봇 계정으로 배선되지 않아 사람 계정이다. 그래서 GitHub 에 쓰는 gh 명령을 막는다. "
         "세션 시작 때 출력된 까닭을 고친 뒤 세션을 다시 시작하면 배선된다. 고치는 법은 " + GUIDE + "에 있다.")
if why or left() < 60:
    deny("봇 토큰이 끝나 가는데 새로 받지 못해 GitHub 에 쓰는 gh 명령을 막는다. "
         + (why or "봇 토큰의 끝나는 시각을 읽지 못했다. " + GUIDE + "을 본다."))
sys.exit(0)
PY
