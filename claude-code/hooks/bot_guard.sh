#!/usr/bin/env bash
# PreToolUse(Bash): 레포에 봇 설정(`.claude/bot.json`)이 있을 때, 세션이 봇 계정을 벗어나
# GitHub 에 쓰는 것을 막는다. 필요: python3 · git(토큰을 새로 받을 때 openssl · curl)
#
# **무엇을 막나.**
# - gh 와 git 의 신원을 바꾸거나 토큰을 꺼내는 명령. 명령 글자에 `GH_CONFIG_DIR` · `GH_TOKEN` ·
#   `GITHUB_TOKEN` · `GH_ENTERPRISE_TOKEN` · `GH_HOST` · `GIT_CONFIG_COUNT` · `GIT_CONFIG_KEY_N` ·
#   `GIT_CONFIG_VALUE_N` · `GIT_CONFIG_PARAMETERS` · `credential.…helper` · `oauth_token` 이 있거나,
#   `gh auth` 명령. `oauth_token` 은 `gh config get -h github.com oauth_token` 이 토큰 전체를 출력해서다.
#   `gh auth` 는 `status` 까지 모두 막는다 — gh 2.92 는 토큰을 마지막 `_` 뒤만 가려, `_` 가 여럿인
#   봇 설치 토큰을 거의 다 출력한다. 사람의 설정이나 토큰으로 바꾸면 세션의 글이 사람의 글로 올라가
#   사람의 결정처럼 읽힌다. 토큰은 모델의 맥락에 들어간다. 환경을 비우는 `env -i`(`--ignore-environment` ·
#   `-`)도 막는다 — 그 뒤의 gh 와 git 은 봇 계정 연결을 잃는다
# - 토큰을 출력하는 명령. `git credential …` · `git credential-<도우미>` 와 봇 디렉터리를 가리키는
#   명령이다(`BOTDIR_READ`). 봇 디렉터리에서는 토큰이 없는 `expires` · `session-env` · `wired` 만 가리킬 수
#   있고, 봇 디렉터리 이름과 `..` 가 한 명령에 함께 있으면 막는다(`wired/../hosts.yml` 처럼 허용한 이름을
#   거쳐 올라간다) — 파일 이름으로 막던 동안 `cat <봇 디렉터리>/*` · `grep -r` 을 막지 못했다. Read 도구는 이
#   훅을 거치지 않으므로 설치되는 `settings.json` 의 `deny` 가 막는다. 그 규칙은 파일 시스템 루트 기준이라
#   (`//**/…`) 작업 디렉터리 밖에 있는 worktree 세션의 봇 디렉터리도 막는다. 연결된 세션의 git 은 github.com 자격 증명을
#   봇(gh)에게서 받으므로 `git credential fill` 이 봇 토큰 전체를 출력한다. 연결되지 않은 세션에서는 사람의
#   토큰을 출력한다
# - 연결되지 않은 세션의 쓰기. 세션 시작 훅(`bot_session.sh`)이 이 세션을 봇 계정에 연결하지
#   못했으면 그 세션의 gh 와 git 은 사람 계정이다. gh 의 읽기 명령이 아닌 것과 `git push` 를 막는다.
#   읽기로 판정하는 것은 아래 `READ_GROUPS` · `READ_SUBS` 와, 메서드 · 필드로 판정해 쓰지 않는 `gh api` 다.
#   목록에 없는 gh 명령은 쓰기로 판정한다 — 목록으로 쓰기를 나열하던 동안 목록 밖의 쓰기
#   (`gh pr update-branch` · `gh run rerun` …)를 막지 못했다
# - 연결된 세션이 github.com 의 SSH 주소로 푸시하는 것. 세션 환경은 github.com 의 SSH 주소를
#   https 로 바꾸지만, 사람의 git 설정(`url.<ssh>.insteadOf` · `pushInsteadOf`)이 https 를 다시 SSH 로
#   바꾸면 그 푸시에는 SSH 키, 곧 사람 계정이 쓰인다. 세션 환경(`<봇 디렉터리>/session-env`)을 적용해
#   실제 푸시 주소를 풀고(`push_urls`), 풀지 못하면 막는다
# - 바로 머지될 PR 에 auto-merge 를 켜는 것. gh 는 바로 머지할 수 있는 PR 에서 `--auto` 를 무시하고 그
#   자리에서 머지하고, 승인을 요구하지 않는 레포에서는 검사가 끝나면 Approve 없이 머지된다. 승인이 모자라
#   막힌 PR(`reviewDecision` `REVIEW_REQUIRED` · `mergeStateStatus` `BLOCKED`)에서만 켜게 하고, 조회하지
#   못하면 막는다(`merge_auto`)
# - auto-merge 가 켜진 PR 의 브랜치로 가는 푸시. 켠 채 푸시하면 사람이 새 커밋을 보고 누른 Approve 로 옛
#   결정 코멘트대로 머지된다. 푸시가 바꿀 브랜치(`push_branches`)의 열린 PR 을 조회하고, 조회하지 못하면
#   막는다
# - 봇 토큰이 끝나 가는데 새로 받지 못한 뒤의 쓰기
#
# **사람 계정으로 올리는 명령은 모양만 본다.** 사람의 결정은 사람 계정 코멘트로 남는다. 그 길은
# `human_comment.sh <PR>` 하나이고, 그 스크립트가 올리는 글은 창 기록 훅(`window_record.sh`)이 봇 디렉터리에
# 적은 기록뿐이다 — 사람이 창에서 고른 보기다. 세션은 그 기록을 읽지도 쓰지도 못하고(위의 봇 디렉터리 막음),
# 창에서 고른 것이 게시 동의라서 권한 프롬프트를 내지 않는다. 한 줄 정규형이 아니거나, 스크립트가 이 훅과
# 같은 디렉터리의 것이 아니거나(세션이 레포의 하위 디렉터리에서 입력한 경우도 여기 든다 — 경로를 cwd 기준으로
# 푼다), 셸의 `-c` 인자 안에 두었으면(`wraps`) 막는다(`human_comment`).
#
# **창 기록 훅을 세션이 직접 실행하면 막는다.** 그 훅에 지어낸 창 결과를 표준입력으로 주면 사람이 고르지 않은
# 결정이 기록되고, 게시 스크립트는 그 기록을 권한 프롬프트 없이 사람 계정으로 올린다. 사람이 정했다 — 작정한
# 우회만이 아니라, 훅이 등록되지 않은 세션이 사람이 창에서 고른 것을 되살리려는 실수도 이 모양이다. 구문 검사
# (`bash -n`)와 읽기는 실행이 아니라 막지 않는다. 이 훅은 cwd 가 봇 설정이 있는 레포 안일 때만 판정하므로, 레포
# 밖을 cwd 로 두고 실행하는 것은 막지 못한다(작정한 우회다).
#
# **명령 치환 안도 본다.** `$(…)` · 백틱 안의 명령을 꺼내 같은 판정을 한다. `url=$(gh pr create …)` ·
# `-H "Authorization: token $(gh auth token)"` 은 흔한 셸 관용구다. heredoc 의 본문은 명령에 전달하는
# 글이라 빼고 판정한다(커밋 메시지 · PR 본문). 다만 GraphQL 의 `mutation` 은 본문을 빼기 전 글자에서
# 찾는다 — 여러 줄 쿼리는 heredoc 으로 전달한다. 조각의 명령 자리에 있는 `gh` 는 이름과 상관없이 호출이고,
# 그 밖의 `gh` 는 바로 뒤 낱말이 gh 의 명령 이름(`GH_GROUPS`)일 때만 호출이다 — `grep -n gh notes.md`
# 의 `gh` 는 인자다.
#
# **토큰을 새로 받는다.** 설치 토큰은 한 시간이면 끝난다. 연결된 세션이 gh 를 부르거나 git 의 원격
# 명령(push · fetch · pull · clone · ls-remote)이나 안에서 gh 를 부르는 판정 스크립트(`human_review.sh`)를
# 실행할 때 토큰이 10분 안에 끝나면, 토큰
# 스크립트(`bot_token.sh`)로 새로 받아 봇 디렉터리의 파일만 바꾼다. `GH_CONFIG_DIR` 은 그대로 그
# 디렉터리를 가리킨다. 연결된 세션의 git 은 github.com 자격 증명을 gh(봇)에게서 받으므로
# (`bot_session.sh`) 푸시 앞에서도 새로 받아야 한다. 새로 받는 데 드는 시간은 토큰 스크립트의 curl
# `--max-time` 이 정한다.
#
# **무엇을 못 막나.** 명령 글자로 알아보므로, 스크립트 파일 안이나 인라인 인터프리터
# (`python3 -c` 등) 안의 호출은 못 본다 — 세션이 봇 연결을 지우는 스크립트를 새로 써서 실행하면 사람
# 계정으로 올라간다. 명령 글자에 위 낱말이 있으면 검색이나 커밋 메시지도 막힌다 — 그 글자를 파일로
# 옮겨 전달한다. 이 훅은 형식대로 입력한 명령의 실수를 막고, 작정한 우회는 막으려 하지 않는다. 작정한
# 우회를 막는 것은 CI 와 브랜치 보호다.
input=$(cat)
# 모든 Bash 호출마다 실행되므로 관련 글자가 없으면 파이썬을 실행하지 않고 끝낸다.
case "$input" in
  *gh*|*git*|*GH_*|*GITHUB_TOKEN*|*GIT_CONFIG*|*credential*|*ai-kit-bot*|*human_comment*|*human_review*|*window_record*|*'env -'*) ;;
  *) exit 0 ;;
esac

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" HOOK_INPUT="$input" python3 - <<'PY'
import datetime, json, os, re, shlex, subprocess, sys

GUIDE = "docs/process/kit-guide.md 의 「봇 계정과 사람의 승인」 절"


def decide(decision, why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


def deny(why):
    decide("deny", why)


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

IDENTITY = re.compile(r'\b(GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GH_HOST'
                      r'|GIT_CONFIG_(?:COUNT|KEY_\d+|VALUE_\d+|PARAMETERS)|oauth_token)\b'
                      r'|credential\.\S*helper')
# gh 의 명령 이름(gh 2.92 의 `gh --help`). 명령 자리가 아닌 `gh` 는 바로 뒤 낱말이 이것일 때만 gh
# 호출로 읽는다 — `grep -n gh notes.md` 의 `gh` 는 인자다. 명령 자리의 `gh` 는 이름과 상관없이
# 호출이다(alias · 확장 · 새 명령).
GH_GROUPS = {'agent-task', 'alias', 'api', 'attestation', 'auth', 'browse', 'cache', 'codespace',
             'completion', 'config', 'copilot', 'extension', 'gist', 'gpg-key', 'help', 'issue',
             'label', 'licenses', 'org', 'pr', 'preview', 'project', 'release', 'repo', 'ruleset',
             'run', 'search', 'secret', 'skill', 'ssh-key', 'status', 'variable', 'version',
             'workflow'}
METHOD = re.compile(r'^(?:-X|--method|--request)(?:=)?([A-Za-z]*)$')
FIELDS = {'-f', '-F', '--field', '--raw-field', '--input', '-d', '--data', '--data-raw',
          '--data-binary'}
# 연결되지 않은 세션에서도 되는 gh 명령. 그 밖은 GitHub 에 쓸 수 있는 것으로 판정한다.
READ_GROUPS = {'search', 'browse', 'status', 'help', 'version', 'completion', 'config', 'alias'}
READ_SUBS = {'view', 'list', 'ls', 'diff', 'checks', 'status', 'download', 'watch', 'clone', 'get',
             'check', 'checkout'}
# 하위 명령 앞에 올 수 있는, 값을 받는 플래그
VALUED = {'-R', '--repo', '--hostname'}
GIT_VALUED = {'-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env'}
GIT_REMOTE = {'push', 'fetch', 'pull', 'clone', 'ls-remote'}
# `git push` 의 긴 플래그 가운데 값을 받는 것(git 2.54 의 `git push -h`). git 은 긴 플래그를 앞 글자만
# 적어도 받으므로 앞부분이 맞으면 값을 받는 것으로 판정한다.
PUSH_VALUED = ('repo', 'receive-pack', 'exec', 'push-option', 'recurse-submodules')
# 명령 자리 앞에 올 수 있는 낱말(래퍼 · 셸 예약어). 그 뒤 첫 낱말이 명령이다.
WRAPPERS = {'env', 'command', 'exec', 'time', 'nice', 'nohup', 'sudo', 'xargs', 'timeout', 'then',
            'do', 'else', 'if', 'while', 'until', '!', '{', '('}
# 봇 디렉터리를 가리키는 글자. 토큰이 없는 파일(`expires` · `session-env` · `wired/`)만 뺀다.
BOTDIR_READ = re.compile(r'ai-kit-bot(?!/(?:expires|session-env|wired)\b)')
HEREDOC = re.compile(r'<<-?[ \t]*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)^[ \t]*\2[ \t]*$',
                     re.S | re.M)


def strip_heredocs(c):
    """heredoc 의 본문을 뺀다. 본문은 명령에 전달하는 글이다 — 커밋 메시지 · PR 본문에 든 `git push` ·
    `gh auth` 를 명령으로 읽으면 안 된다. 끝 줄이 있을 때만 뺀다 — 끝 줄이 없으면 heredoc 이 아니거나
    (따옴표 안의 `<<EOF`) 셸이 명령 끝까지를 본문으로 읽는데, 어느 쪽인지 모르므로 판정에 남긴다.
    `bash <<'EOF'` 처럼 본문을 실행하는 꼴은 스크립트 파일처럼 못 본다."""
    return HEREDOC.sub(lambda m: m.group(0)[:m.start(3) - m.start(0)] + '\n', c)


def segments(c):
    """명령을 `;` · `&&` · `||` · `|` · `&` · 줄바꿈에서 나눈 낱말 목록들. 따옴표 안은 한 낱말이다.

    리다이렉션(`>파일` · `2>&1` · `<<끝말`)은 그 대상 · 앞의 파일 번호와 함께 뺀다 — 푸시의 원격 자리를
    `2>` 나 `>파일` 로 읽으면 주소를 못 푼다. 파일 번호가 띄어 쓴 인자와 구분되지 않아(`push x 2 >f`
    의 `2`) 숫자만인 인자도 빠지지만, 그 자리에 숫자만 오는 명령은 드물다."""
    try:
        lex = shlex.shlex(c.replace('\n', ' ; '), posix=True, punctuation_chars=';&|<>')
        lex.whitespace_split = True
        lex.commenters = ''
        toks = list(lex)
    except ValueError:
        toks = re.findall(r'[;&|<>]+|[^\s;&|<>]+', c.replace('\n', ' ; '))
    out, cur, target = [], [], False
    for t in toks:
        if target:
            target = False
        elif t and set(t) <= set(';&|<>') and set(t) & set('<>'):
            if cur and cur[-1].isdigit():
                cur.pop()
            target = True
        elif t and set(t) <= set(';&|'):
            out.append(cur)
            cur = []
        else:
            cur.append(t)
    out.append(cur)
    return [s for s in out if s]


def substitutions(c):
    """`$(…)` 와 백틱 안의 명령. 괄호 짝을 세고, 안의 따옴표 속 괄호는 세지 않는다.

    shlex 는 `x=$(gh` · `"$(gh pr comment …)"` 를 한 낱말로 두어, 명령 치환 안의 gh · git 이 호출로
    보이지 않는다. 그래서 안의 명령을 꺼내 따로 판정한다. 작은따옴표 안의 글자도 꺼낸다(막는 쪽으로 틀린다).
    """
    out, i, n = [], 0, len(c)
    while i < n:
        if c.startswith('$(', i) and not c.startswith('$((', i):
            depth, j, q = 1, i + 2, ''
            while j < n and depth:
                ch = c[j]
                if q:
                    q = '' if ch == q else q
                elif ch in '\'"':
                    q = ch
                elif ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                j += 1
            inner = c[i + 2:j - 1] if depth == 0 else c[i + 2:]
            out += [inner] + substitutions(inner)
            i = j
        elif c[i] == '`':
            j = c.find('`', i + 1)
            out.append(c[i + 1:j] if j >= 0 else c[i + 1:])
            i = j + 1 if j >= 0 else n
        else:
            i += 1
    return out


def calls(seg, name):
    """한 조각에서 `name`(gh · git) 호출마다 그 뒤 낱말들을 돌려준다."""
    starts = [i for i, t in enumerate(seg) if os.path.basename(t) == name]
    return [seg[i + 1:(starts[k + 1] if k + 1 < len(starts) else len(seg))]
            for k, i in enumerate(starts)]


def head(seg):
    """조각의 명령 자리. 앞의 `이름=값` · 래퍼 · 래퍼의 플래그와 숫자를 건너뛴다."""
    i = 0
    while i < len(seg) and (re.match(r'^[A-Za-z_]\w*=', seg[i]) or seg[i] in WRAPPERS
                            or seg[i].startswith('-') or seg[i].isdigit()):
        i += 1
    return i


def gh_calls_in(seg):
    """조각의 gh 호출. 명령 자리의 gh 는 늘, 그 밖의 gh 는 뒤 낱말이 gh 의 명령 이름일 때만."""
    at = head(seg)
    got, starts = [], [i for i, t in enumerate(seg) if os.path.basename(t) == 'gh']
    for k, i in enumerate(starts):
        a = seg[i + 1:(starts[k + 1] if k + 1 < len(starts) else len(seg))]
        if i == at or (words(a, 1) or [''])[0] in GH_GROUPS:
            got.append(a)
    return got


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
            return 'mutation' in cmd
        return rest_writes(args)
    if w[0] in READ_GROUPS or w[0] == 'auth':
        return False
    return not (len(w) > 1 and w[1] in READ_SUBS)


def clears_env(seg):
    """조각이 `env -i` · `env --ignore-environment` · `env -` 로 환경을 비우고 명령을 실행하는가."""
    for i, t in enumerate(seg):
        if os.path.basename(t) != 'env':
            continue
        for u in seg[i + 1:]:
            if u in ('-', '--ignore-environment') or re.match(r'^-[A-Za-z]*i[A-Za-z]*$', u):
                return True
            if not (u.startswith('-') or '=' in u):
                break
    return False


SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh', 'source', '.'}


def runs(seg, name):
    """조각이 스크립트 `name` 을 실행하는가. 셸에 `-n`(구문 검사)을 준 것과 인자로 나온 것
    (`git add` · `cat`)은 실행이 아니다."""
    at = head(seg)
    if at >= len(seg):
        return False
    if os.path.basename(seg[at]) == name:
        return True
    if os.path.basename(seg[at]) not in SHELLS:
        return False
    rest = seg[at + 1:]
    script = next((t for t in rest if not t.startswith('-')), '')
    return os.path.basename(script) == name and '-n' not in rest[:rest.index(script)]


def wraps(seg, name):
    """조각이 셸의 `-c` 인자 안에서 스크립트 `name` 을 부르는가. 그 인자는 조각으로 나누지 않으므로
    `runs` 가 보지 못한다(`bash -c '… human_comment.sh …'`)."""
    at = head(seg)
    if at >= len(seg) or os.path.basename(seg[at]) not in SHELLS:
        return False
    rest = seg[at + 1:]
    for k, t in enumerate(rest):
        if re.match(r'^-[A-Za-z]*c[A-Za-z]*$', t):
            return k + 1 < len(rest) and name in rest[k + 1]
        if not t.startswith('-'):
            return False
    return False


HUMAN = re.compile(r'bash[ \t]+(\S+)[ \t]+(\d+)(?:[ \t]+-R[ \t]+(\S+))?')
HUMAN_CANON = "`bash .claude/hooks/human_comment.sh <PR 번호> [-R <owner/repo>]`"


def human_comment():
    """사람 계정으로 올리는 명령이 한 줄 정규형이고 이 훅과 같은 디렉터리의 스크립트인지 본다.

    그 스크립트가 올리는 글은 창 기록 훅(`window_record.sh`)이 적은 기록뿐이다 — 사람이 창에서 고른 보기로
    만든 줄이고, 세션은 그 기록을 읽지도 쓰지도 못한다. 창에서 고른 것이 게시 동의라서 권한 프롬프트를 내지
    않는다. 다른 명령과 이으면 무엇이 실행되는지 이 훅이 다 알지 못하므로 한 줄 정규형만 받는다."""
    line = cmd.strip()
    m = HUMAN.fullmatch(line)
    if not m or re.search(r'[;&|<>$`\\\'"\n()]', line):
        deny("사람 계정으로 올리는 명령은 한 줄 정규형으로 따로 입력한다: " + HUMAN_CANON + ". 올리는 글은 "
             "창에서 사람이 고른 보기의 기록뿐이라 본문 파일을 받지 않는다. 다른 명령과 잇거나 명령 치환 · "
             "따옴표 · 리다이렉트를 쓰면 무엇이 실행되는지 이 훅이 알 수 없다.")
    mine = os.path.realpath(os.path.join(os.environ['HOOK_DIR'], 'human_comment.sh'))
    if os.path.realpath(os.path.join(cwd or os.getcwd(), m.group(1))) != mine:
        # 알려 주는 경로는 레포 루트에서 이 훅의 스크립트까지다 — 설치된 레포는 `.claude/hooks/…` 이고, 훅을
        # 다른 곳에서 등록한 레포(킷 레포)는 그 자리다
        rel = os.path.relpath(mine, os.path.realpath(top.stdout.strip()))
        deny("사람 계정으로 올리는 스크립트는 이 훅과 같은 디렉터리의 것만 받는다: " + mine + ". 레포 루트에서 "
             "`bash " + rel + " <PR 번호> [-R <owner/repo>]` 로 입력한다 — 세션이 하위 디렉터리에 있으면 먼저 "
             "cd 로 레포 루트로 옮긴다(한 줄로 잇지 않는다). 설치되는 settings.json 의 allow 도 그 모양만 받는다.")


body = strip_heredocs(cmd)
segs = [s for c in [body] + substitutions(body) for s in segments(c)]
gh_calls = [a for s in segs for a in gh_calls_in(s)]
git_calls = [a for s in segs for a in calls(s, 'git')]
git_subs = [(words(a, 1, GIT_VALUED) or [''])[0] for a in git_calls]

if IDENTITY.search(cmd):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, 세션의 gh 와 git 은 봇 계정으로만 쓴다. gh 의 "
         "설정 · 토큰과 git 의 자격 증명을 바꾸는 명령(GH_CONFIG_DIR · GH_TOKEN · GITHUB_TOKEN · "
         "GIT_CONFIG_* · credential.helper)은 막는다 — 사람의 계정으로 바꾸면 세션의 글이 사람의 글로 남아 "
         "사람의 결정처럼 읽힌다. 그 낱말이 검색어나 글이면 파일로 옮겨 전달한다.")
if any(words(a, 1) == ['auth'] for a in gh_calls):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, gh auth 명령은 모두 막는다. 계정을 바꾸면 세션이 "
         "사람 계정으로 쓰고, gh auth status 도 봇 설치 토큰을 거의 다 출력해 토큰이 모델의 맥락에 들어간다. "
         "이 세션의 gh 계정은 세션 시작 때 출력된 줄에 있다. 그 낱말이 검색어나 글이면 파일로 옮겨 전달한다.")
if any(s == 'credential' or s.startswith('credential-') for s in git_subs) or re.search(
        BOTDIR_READ, cmd) or ('ai-kit-bot' in cmd and '..' in cmd):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, 토큰을 출력하는 명령은 막는다 — git credential 과 "
         "봇 디렉터리(ai-kit-bot)를 가리키는 명령이다. 토큰이 없는 expires · session-env · wired 는 읽을 수 "
         "있지만, 봇 디렉터리 이름과 .. 가 함께 있으면 막는다. 연결된 세션의 git 은 자격 증명을 봇에게서 받으므로 git credential fill 이 봇 토큰 전체를 "
         "출력하고, 토큰은 모델의 맥락에 들어간다. 그 낱말이 검색어나 글이면 파일로 옮겨 전달한다.")
if any(clears_env(s) for s in segs):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 있어, 환경을 비우는 env -i(--ignore-environment · -)는 "
         "막는다. 그 뒤의 gh 와 git 은 봇 계정 연결을 잃고 사람 계정으로 쓴다. 사람 계정으로 올릴 결정은 "
         "human_comment.sh 로 올린다.")
if any(runs(s, 'window_record.sh') or wraps(s, 'window_record.sh') for s in segs):
    deny("창 기록 훅(window_record.sh)은 Claude Code 가 질문 창이 끝날 때 실행한다. 세션이 직접 실행하면 사람이 "
         "고르지 않은 결정이 기록돼 사람 계정으로 올라가므로 막는다. 창 뒤에 창 기록 훅의 안내가 오지 않았으면 "
         "open-pr 3.5 대로 한다 — 질문의 게시 표지가 글자 그대로가 아니면 고쳐 같은 창을 다시 띄우고, 표지가 "
         "맞으면 훅이 실행되지 않은 것이라 PR 링크와 쓸 글을 적어 PR 웹에 써 달라고 요청한다.")
if any(wraps(s, 'human_comment.sh') for s in segs):
    deny("사람 계정으로 올리는 명령을 셸의 -c 인자 안에 두면 이 훅이 그 모양을 보지 못해 막는다. 한 줄 "
         "정규형으로 따로 입력한다: " + HUMAN_CANON)
if any(runs(s, 'human_comment.sh') for s in segs):
    human_comment()

# 판정 스크립트는 안에서 gh 를 부른다(`merge-pr` 2절). 명령 글자에 gh 가 없어도 토큰이 살아 있어야 한다.
remote = any(s in GIT_REMOTE for s in git_subs) or any(runs(s, 'human_review.sh') for s in segs)
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


def git_parts(args):
    """git 호출 하나의 전역 옵션(`-C` · `-c` …) · 하위 명령 · 그 뒤 낱말."""
    i = 0
    while i < len(args) and args[i].startswith('-'):
        i += 2 if args[i] in GIT_VALUED else 1
    return args[:i], (args[i] if i < len(args) else ''), args[i + 1:]


def push_remote(rest):
    """`git push` 의 낱말에서 원격(이름이나 URL)을 꺼낸다. 주지 않았으면 ''.

    원격은 플래그가 아닌 첫 낱말이고, 없으면 `--repo` 의 값이다. 값을 받는 플래그의 값(`-o ci.skip`)은
    건너뛴다. 짧은 플래그는 `-o` 만 값을 받고, 묶어 쓰면(`-uo x`) 끝 글자가 `o` 일 때 다음 낱말이 값이다."""
    repo, i = '', 0
    while i < len(rest):
        t = rest[i]
        i += 1
        if t == '--':
            return rest[i] if i < len(rest) else repo
        if not t.startswith('-') or t == '-':
            return t
        if t.startswith('--'):
            name, eq, val = t[2:].partition('=')
            if name == 'repo':
                repo = val if eq else (rest[i] if i < len(rest) else '')
                i += 0 if eq else 1
            elif not eq and name and any(v.startswith(name) for v in PUSH_VALUED):
                i += 1
        elif t.find('o', 1) == len(t) - 1:
            i += 1
    return repo


def session_run(prog, *a):
    """세션 환경(`<봇 디렉터리>/session-env`)을 적용해 git · gh 를 실행한다. 이 훅은 세션의 Bash 가 받는
    환경을 받지 않으므로, 세션의 명령이 쓸 설정 · 계정을 보려면 그 파일을 적용해야 한다."""
    return subprocess.run(
        ['bash', '-c', '[ -f "$0" ] && { set -a; . "$0"; set +a; }; exec "$@"',
         os.path.join(botdir, 'session-env'), prog, *a], cwd=cwd, capture_output=True, text=True)


def push_urls(args):
    """연결된 세션의 git 이 이 푸시에 실제로 쓸 주소들. 풀지 못하면 빈 목록이다.

    세션 환경(`session-env`)과 그 호출의 전역 옵션을 적용한 `git config` 를 읽어, git 이 푸시 주소를 푸는
    규칙대로 푼다(git 의 `remote.c`). `git remote get-url` 은 `-c` 로만 준 원격을 모르고
    `git ls-remote --get-url` 은 pushInsteadOf 를 적용하지 않아 쓰지 않는다.
    - 원격을 주지 않으면 `branch.<지금 브랜치>.pushRemote` → `remote.pushDefault` →
      `branch.<지금 브랜치>.remote` → origin 이다.
    - 원격에 `pushurl` 이 있으면 그것에 insteadOf 를 적용한 것이다.
    - 없으면 원격의 `url`(원격 설정이 없으면 원격 자리에 적은 URL)마다 pushInsteadOf 를 적용한 것이고,
      pushInsteadOf 가 맞는 URL 이 하나도 없으면 insteadOf 를 적용한 것이다.
    - 규칙이 여럿 맞으면 바꿀 앞부분이 가장 긴 것을 쓴다."""
    pre, _, rest = git_parts(args)

    def git(*a):
        return session_run('git', *pre, *a)

    def cfg(key):
        return git('config', '--get-all', key).stdout.splitlines()

    if git('rev-parse', '--git-dir').returncode:
        return []
    remote = push_remote(rest)
    if not remote:
        branch = git('symbolic-ref', '-q', '--short', 'HEAD').stdout.strip()
        keys = ['branch.%s.pushRemote' % branch] * bool(branch) + ['remote.pushDefault'] + \
            ['branch.%s.remote' % branch] * bool(branch)
        remote = next((v[-1] for v in map(cfg, keys) if v), 'origin')
    rules = {'insteadof': [], 'pushinsteadof': []}
    for item in git('config', '-z', '--get-regexp', r'^url\..*\.(push)?insteadof$').stdout.split('\0'):
        key, _, prefix = item.partition('\n')
        m = re.match(r'^url\.(.*)\.(pushinsteadof|insteadof)$', key, re.S)
        if m:
            rules[m.group(2)].append((m.group(1), prefix))

    def alias(url, kind):
        best = None
        for base, prefix in rules[kind]:
            if url.startswith(prefix) and (best is None or len(prefix) > len(best[1])):
                best = (base, prefix)
        return best[0] + url[len(best[1]):] if best else None

    pushurls = cfg('remote.%s.pushurl' % remote)
    if pushurls:
        return [alias(u, 'insteadof') or u for u in pushurls]
    urls = cfg('remote.%s.url' % remote) or [remote]
    return [p for u in urls for p in [alias(u, 'pushinsteadof')] if p] or \
        [alias(u, 'insteadof') or u for u in urls]


# `gh pr merge` 의 플래그 가운데 값을 받는 것(gh 2.92 의 `gh pr merge --help`)
MERGE_VALUED = {'-R', '--repo', '-t', '--subject', '-b', '--body', '-F', '--body-file',
                '--match-head-commit', '-A', '--author-email'}


def merge_auto(args):
    """gh 호출 하나가 auto-merge 를 켜는 `gh pr merge --auto` 면 (PR 자리, 레포)를, 아니면 None 을 돌려준다.
    PR 자리를 주지 않았으면 ''(지금 브랜치의 PR)이다."""
    if words(args, 2) != ['pr', 'merge']:
        return None
    if not any(t == '--auto' or (t.startswith('--auto=') and t[7:].lower() not in ('false', '0'))
               for t in args):
        return None
    pos, repo, i = [], '', 0
    while i < len(args):
        t = args[i]
        i += 1
        if t in ('-R', '--repo'):
            repo, i = (args[i] if i < len(args) else ''), i + 1
        elif t.startswith('--repo='):
            repo = t[7:]
        elif t.startswith('-R') and len(t) > 2:
            repo = t[2:]
        elif t in MERGE_VALUED:
            i += 1
        elif not t.startswith('-'):
            pos.append(t)
    return (pos[2] if len(pos) > 2 else ''), repo


def push_branches(args):
    """`git push` 가 바꿀 수 있는 원격 브랜치 이름들. 모든 브랜치이거나 알 수 없으면 None.

    원격 다음 낱말이 refspec 이고, 받는 쪽(`:` 뒤, 없으면 그 낱말)이 브랜치다. refspec 이 없으면 지금
    브랜치를 푸시한다(git 의 기본 `push.default=simple`)."""
    pre, _, rest = git_parts(args)
    pos, i, every = [], 0, False
    while i < len(rest):
        t = rest[i]
        i += 1
        if t == '--':
            pos += rest[i:]
            break
        if not t.startswith('-') or t == '-':
            pos.append(t)
        elif t.startswith('--'):
            name, eq, _ = t[2:].partition('=')
            if name in ('all', 'branches', 'mirror'):
                every = True
            elif not eq and name and any(v.startswith(name) for v in PUSH_VALUED):
                i += 1
        elif t.find('o', 1) == len(t) - 1:
            i += 1
    if every:
        return None
    cur = session_run('git', *pre, 'symbolic-ref', '-q', '--short', 'HEAD').stdout.strip()
    got = set()
    for r in pos[1:] or ['HEAD']:
        dst = r.lstrip('+').split(':', 1)[-1]
        if dst in ('HEAD', '@', ''):
            dst = cur
        if not dst or '*' in dst:
            return None
        got.add(re.sub(r'^refs/heads/', '', dst))
    return got


# gh 는 바로 머지할 수 있는 PR(CLEAN · HAS_HOOKS · UNSTABLE)에서 `--auto` 를 무시하고 그 자리에서 머지한다
# (gh v2.92.0 `pkg/cmd/pr/merge/merge.go` 의 `isImmediatelyMergeable`). 승인을 요구하지 않는 레포라면
# 검사가 끝나 막힘이 풀리는 순간 Approve 없이 머지된다. 그래서 승인이 모자라 막힌 PR 에서만 켠다.
for a in gh_calls:
    target = merge_auto(a)
    if target is None:
        continue
    sel, repo = target
    r = session_run('gh', 'pr', 'view', *([sel] if sel else []), *(['-R', repo] if repo else []),
                    '--json', 'reviewDecision,mergeStateStatus')
    try:
        st = json.loads(r.stdout) if not r.returncode else None
    except ValueError:
        st = None
    if not isinstance(st, dict):
        deny("PR 의 상태를 조회하지 못해 auto-merge 를 켜는 명령을 막는다. 조회가 되는지 `gh pr view "
             + (sel or '') + " --json reviewDecision,mergeStateStatus` 로 본 뒤 다시 실행한다.")
    if (st.get('reviewDecision'), st.get('mergeStateStatus')) != ('REVIEW_REQUIRED', 'BLOCKED'):
        deny("auto-merge 는 승인이 모자라 막힌 PR(reviewDecision REVIEW_REQUIRED · mergeStateStatus "
             "BLOCKED)에서만 켠다. 지금은 reviewDecision %s · mergeStateStatus %s 다. gh 는 바로 머지할 수 "
             "있는 PR 에서 --auto 를 무시하고 그 자리에서 머지하고, 승인을 요구하지 않는 레포에서는 검사가 "
             "끝나면 Approve 없이 머지된다. 상태가 UNKNOWN 이면 잠시 뒤 다시 실행한다. 그 밖의 상태에서는 "
             "merge-pr 2절의 「그 밖이면 세션이 Approve 를 확인한다」를 따른다(사람이 Approve 한 뒤 "
             "human_review.sh 로 확인하고 --auto 없이 머지)." % (st.get('reviewDecision'), st.get('mergeStateStatus')))

# 세션 환경은 github.com 의 SSH 주소를 https 로 바꾸지만, 사람의 git 설정이 https 를 다시 SSH 로 바꾸면
# (`url.<ssh>.insteadOf` · `pushInsteadOf`) 그 푸시에는 SSH 키, 곧 사람 계정이 쓰인다.
for a in git_calls:
    if git_parts(a)[1] != 'push':
        continue
    urls = push_urls(a)
    if not urls:
        deny("이 푸시의 주소를 풀지 못해 막는다. 막기 훅은 푸시 주소가 github.com 의 SSH 주소가 아닌지, "
             "곧 사람 계정으로 푸시하지 않는지 확인한 뒤에 푸시를 통과시킨다. 원격 이름이나 URL 을 적어 다시 "
             "실행한다.")
    for u in urls:
        if re.search(r'github\.com[:/]', u) and not u.startswith('https://github.com/'):
            deny("이 푸시의 주소는 " + u + " 이다. github.com 의 SSH 주소라서 봇이 아니라 SSH 키, 곧 사람 계정으로 "
                 "푸시된다. 세션은 github.com 의 SSH 주소를 https 로 바꿔 쓰지만, 사람의 git 설정(url.….insteadOf · "
                 "pushInsteadOf)이 https 를 SSH 로 다시 바꾼다. 그 설정을 이 레포에서 끄는 법은 " + GUIDE + "에 있다.")
    # auto-merge 를 켠 뒤 그 브랜치에 푸시하면, 사람이 새 커밋을 보고 누른 Approve 로 옛 결정 코멘트대로
    # 머지된다. 먼저 끄게 한다.
    slugs = {m.group(1) for u in urls
             for m in [re.match(r'^https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$', u)] if m}
    if not slugs:
        continue
    targets = push_branches(a)
    for slug in sorted(slugs):
        r = session_run('gh', 'pr', 'list', '-R', slug, '--state', 'open', '--limit', '100',
                        '--json', 'number,headRefName,autoMergeRequest')
        try:
            prs = json.loads(r.stdout) if not r.returncode else None
        except ValueError:
            prs = None
        if not isinstance(prs, list):
            deny("이 푸시가 바꿀 브랜치의 PR 에 auto-merge 가 켜져 있는지 조회하지 못해 막는다. `gh pr list -R "
                 + slug + " --json number,headRefName,autoMergeRequest` 가 되는지 본 뒤 다시 실행한다.")
        for p in prs:
            if p.get('autoMergeRequest') and (targets is None or p.get('headRefName') in targets):
                deny("PR #%s 에 auto-merge 가 켜져 있어 그 브랜치(%s)에 푸시하는 것을 막는다. 켠 채 푸시하면 "
                     "사람이 새 커밋을 보고 누른 Approve 로 옛 결정 코멘트대로 머지된다. 먼저 `gh pr merge %s "
                     "--disable-auto` 로 끄고, 옛 결정 코멘트 뒤에 「auto-merge 를 껐다. 이 결정 코멘트로는 머지하지 "
                     "않는다.」 한 줄을 남긴 뒤 푸시하고, 2절부터 다시 한다 — 2절이 새 커밋을 나열하며 멈추고, "
                     "한 라운드 더 할지는 사람이 정한다(merge-pr 3절 「머지되기 전에 다시 해야 하면 먼저 끈다」)."
                     % (p.get('number'), p.get('headRefName'), p.get('number')))
sys.exit(0)
PY
