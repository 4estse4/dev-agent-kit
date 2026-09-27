#!/usr/bin/env bash
# PreToolUse(Bash): 레포에 봇 설정(`.claude/bot.json`)이 있을 때, 세션이 봇 계정을 벗어나
# GitHub 에 쓰는 것을 막는다. 필요: python3 · git(토큰을 새로 받을 때 openssl · curl)
#
# **무엇을 막나.**
# - 세션이 👍 를 다는 명령. REST 의 `…/reactions` 에 쓰는 호출(`-X`/`--method` 가 GET 이 아니거나,
#   `-f` · `-F` · `--field` · `--raw-field` · `--input` · `-d` · `--data` 를 준 호출)과 GraphQL 의
#   `addReaction`. 👍 는 사람이 3.5 코멘트를 승인하는 표시라서, 세션이 달면 스스로 승인하는 셈이다
# - gh 의 신원을 바꾸거나 토큰을 꺼내는 명령. 명령 글자에 `GH_CONFIG_DIR` · `GH_TOKEN` ·
#   `GITHUB_TOKEN` · `GH_ENTERPRISE_TOKEN` · `GH_HOST` 가 있거나, `gh auth` 의 `status` 가 아닌
#   하위 명령, 토큰을 출력하는 `gh auth status -t` · `--show-token`. 사람의 gh 설정이나 토큰으로
#   바꾸면 세션의 글이 사람의 글로 올라가고 사람의 👍 도 달 수 있다. 토큰은 모델의 맥락에 들어간다
# - 연결되지 않은 세션의 쓰기. 세션 시작 훅(`bot_session.sh`)이 이 세션의 gh 를 봇 계정에 연결하지
#   못했으면 그 세션의 gh 는 사람 계정이고, git 이 자격 증명을 gh 로 받으면 푸시도 사람 계정이다.
#   gh 의 읽기 명령이 아닌 것과 `git push` 를 막는다. 읽기로 보는 것은 아래 `READ_GROUPS` ·
#   `READ_SUBS` 와, 메서드 · 필드로 판정해 쓰지 않는 `gh api` 다. 목록에 없는 gh 명령은 쓰기로 본다
#   — 목록으로 쓰기를 나열하던 동안 목록 밖의 쓰기(`gh pr update-branch` · `gh run rerun` …)가
#   지나갔다
# - 봇 토큰이 끝나 가는데 새로 받지 못한 뒤의 쓰기
#
# **토큰을 새로 받는다.** 설치 토큰은 한 시간이면 끝난다. 연결된 세션이 gh 를 부르거나 git 의 원격
# 명령(push · fetch · pull · clone · ls-remote)을 실행할 때 토큰이 10분 안에 끝나면, 토큰
# 스크립트(`bot_token.sh`)로 새로 받아 봇 디렉터리의 파일만 바꾼다. `GH_CONFIG_DIR` 은 그대로 그
# 디렉터리를 가리킨다. git 은 자격 증명을 gh 에서 받으므로 푸시 앞에서도 새로 받아야 한다. 새로 받는
# 데 드는 시간은 토큰 스크립트의 curl `--max-time` 이 정한다.
#
# **무엇을 못 막나.** 명령 글자로 알아보므로, 스크립트 파일 안이나 인라인 인터프리터
# (`python3 -c` 등) 안의 호출은 못 본다. 명령 글자에 위 낱말이 있으면 검색이나 커밋 메시지도
# 막힌다 — 그 글자를 파일로 옮겨 전달한다. 이 훅은 형식대로 입력한 명령의 실수를 막고, 작정한
# 우회는 막으려 하지 않는다. 작정한 우회를 막는 것은 CI 와 브랜치 보호다.
input=$(cat)
# 모든 Bash 호출마다 실행되므로 관련 글자가 없으면 파이썬을 실행하지 않고 끝낸다.
case "$input" in
  *gh*|*git*|*GH_*|*GITHUB_TOKEN*|*reactions*|*addReaction*) ;;
  *) exit 0 ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" HOOK_INPUT="$input" python3 - <<'PY'
import datetime, json, os, re, shlex, subprocess, sys

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
METHOD = re.compile(r'^(?:-X|--method|--request)(?:=)?([A-Za-z]*)$')
FIELDS = {'-f', '-F', '--field', '--raw-field', '--input', '-d', '--data', '--data-raw',
          '--data-binary'}
# 연결되지 않은 세션에서도 되는 gh 명령. 그 밖은 GitHub 에 쓸 수 있는 것으로 본다.
READ_GROUPS = {'search', 'browse', 'status', 'help', 'version', 'completion', 'config', 'alias'}
READ_SUBS = {'view', 'list', 'ls', 'diff', 'checks', 'status', 'download', 'watch', 'clone', 'get',
             'check'}
# 하위 명령 앞에 올 수 있는, 값을 받는 플래그
VALUED = {'-R', '--repo', '--hostname'}
GIT_VALUED = {'-C', '-c', '--git-dir', '--work-tree', '--namespace'}
GIT_REMOTE = {'push', 'fetch', 'pull', 'clone', 'ls-remote'}


def segments(c):
    """명령을 `;` · `&&` · `||` · `|` · `&` · 줄바꿈에서 나눈 낱말 목록들. 따옴표 안은 한 낱말이다."""
    try:
        lex = shlex.shlex(c.replace('\n', ' ; '), posix=True, punctuation_chars=';&|')
        lex.whitespace_split = True
        lex.commenters = ''
        toks = list(lex)
    except ValueError:
        toks = c.split()
    out, cur = [], []
    for t in toks:
        if t and set(t) <= set(';&|'):
            out.append(cur)
            cur = []
        else:
            cur.append(t)
    out.append(cur)
    return [s for s in out if s]


def calls(seg, name):
    """한 조각에서 `name`(gh · git) 호출마다 그 뒤 낱말들을 돌려준다."""
    starts = [i for i, t in enumerate(seg) if os.path.basename(t) == name]
    return [seg[i + 1:(starts[k + 1] if k + 1 < len(starts) else len(seg))]
            for k, i in enumerate(starts)]


def words(args, n, valued=VALUED):
    """플래그와 그 값을 건너뛴 앞 낱말 n 개."""
    got, i = [], 0
    while i < len(args) and len(got) < n:
        t = args[i]
        if t in valued:
            i += 2
            continue
        if not t.startswith('-'):
            got.append(t)
        i += 1
    return got


def rest_writes(args):
    """REST 호출이 쓰는가. 메서드가 있으면 그것으로, 없으면 필드가 있는지로 본다(필드가 있으면 POST)."""
    for i, t in enumerate(args):
        m = METHOD.match(t)
        if m:
            method = m.group(1) or (args[i + 1] if i + 1 < len(args) else '')
            return method.strip('"\'').upper() != 'GET'
    return any(t.split('=', 1)[0] in FIELDS for t in args)


def gh_writes(args):
    """gh 호출 하나가 GitHub 에 쓸 수 있는가."""
    if '-h' in args or '--help' in args:
        return False
    w = words(args, 2)
    if not w:
        return False
    if w[0] == 'api':
        if len(w) > 1 and w[1] == 'graphql':
            return any('mutation' in t for t in args)
        return rest_writes(args)
    if w[0] in READ_GROUPS or w[0] == 'auth':
        return False
    return not (len(w) > 1 and w[1] in READ_SUBS)


segs = segments(cmd)
gh_calls = [a for s in segs for a in calls(s, 'gh')]
git_subs = [(words(a, 1, GIT_VALUED) or [''])[0] for s in segs for a in calls(s, 'git')]

if IDENTITY.search(cmd):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, 세션의 gh 는 봇 계정으로만 쓴다. gh 의 설정 · "
         "토큰 · 계정을 바꾸는 명령(GH_CONFIG_DIR · GH_TOKEN · GITHUB_TOKEN · gh auth)은 막는다 — "
         "사람의 계정으로 바꾸면 세션의 글이 사람의 글로 남고 사람의 👍 도 달 수 있다. 그 낱말이 검색어나 "
         "글이면 파일로 옮겨 전달한다.")
for a in gh_calls:
    w = words(a, 2)
    if w[:1] == ['auth'] and (w[1:2] != ['status'] or '-t' in a or '--show-token' in a):
        deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, gh 의 계정을 바꾸거나 토큰을 꺼내는 "
             "gh auth 명령(status 의 -t · --show-token 포함)은 막는다. 토큰은 모델의 맥락에 들어가고, "
             "사람의 토큰이면 세션이 사람 계정으로 쓸 수 있다. 인증 상태는 gh auth status 로 본다.")
reacts = 'addReaction' in cmd or any(
    any('reactions' in t for t in a) and w[:1] == ['api'] and gh_writes(a)
    for a in gh_calls for w in [words(a, 2)]) or any(
    any('reactions' in t for t in s) and rest_writes(s) for s in segs if not calls(s, 'gh'))
if reacts:
    deny("세션은 👍 를 달지 않는다. 3.5 코멘트의 👍 는 사람이 자기 계정으로 달아 승인하는 표시다. "
         "사람에게 그 코멘트에 👍 를 달아 달라고 알린다.")

remote = any(s in GIT_REMOTE for s in git_subs)
if not gh_calls and not remote:
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
                       capture_output=True, text=True)
    if r.returncode:
        why = r.stdout.strip()

if not (any(gh_writes(a) for a in gh_calls) or 'push' in git_subs):
    sys.exit(0)
if not wired:
    deny("이 세션의 gh 는 봇 계정에 연결되지 않아 사람 계정이다. 그래서 GitHub 에 쓰는 gh 명령과 "
         "git push 를 막는다. 세션 시작 때 출력된 까닭을 고친 뒤 세션을 다시 시작하면 연결된다. "
         "고치는 법은 " + GUIDE + "에 있다.")
if why or left() < 60:
    deny("봇 토큰이 끝나 가는데 새로 받지 못해 GitHub 에 쓰는 gh 명령과 git push 를 막는다. "
         + (why or "봇 토큰의 끝나는 시각을 읽지 못했다. " + GUIDE + "을 본다."))
sys.exit(0)
PY
