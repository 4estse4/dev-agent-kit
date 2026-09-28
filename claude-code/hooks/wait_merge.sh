#!/usr/bin/env bash
# auto-merge 를 켠 PR 을 기다리다가, 사람이 봐야 할 일이 생기면 그 까닭을 한 줄 출력하고 끝난다.
# 필요: python3 · gh · git
#
#     bash .claude/hooks/wait_merge.sh <PR 번호> [-R <owner/repo>]
#
# 세션은 auto-merge 를 켠 뒤(`merge-pr` 3절 「봇 설정이 있을 때」) 이것을 Bash 의 `run_in_background` 로 실행하고
# 턴을 끝낸다. 백그라운드 명령이 끝나면 Claude Code 가 세션을 깨운다 — 그래서 사람이 머지됐다고 알리지 않아도
# 세션이 머지를 안다. 기한은 없다. 협업에서는 Approve 가 며칠 뒤에 달릴 수 있고, 기한이 끝나면 결국 사람이
# 알려야 한다. 1분에 한 번 조회한다(`WAIT_MERGE_INTERVAL` 에 초로 적으면 바뀐다 — 테스트가 줄인다).
#
# **기다리는 동안 세션 프로세스는 멈추지 않는다.** Claude Code 의 agent view 는 입력을 기다리며 한 시간쯤 아무도
# 붙어 있지 않은 백그라운드 세션의 프로세스를 멈춘다. 백그라운드 명령이 실행되는 동안에는 그 세션을 일하는
# 중(`claude agents --json` 의 `working`)으로 센다 — 90분짜리 명령을 켜고 턴을 끝낸 백그라운드 세션에 아무도
# 붙지 않았는데 프로세스가 그대로였고, 명령이 끝나자 같은 프로세스가 깨어났다(2026-09-28 에 확인했다).
#
# **끝나는 까닭.** 출력의 `:` 앞이 까닭이다. 머지됨 · 이미 기다림이면 0, 그 밖은 1 로 끝난다.
# - 머지됨 · 닫힘(머지 없이) · auto-merge 꺼짐 · head 바뀜(누가 푸시했다. PR 웹의 「Update branch」 포함)
# - 사람의 글: 시작한 뒤 달린 사람 계정의 코멘트나 Approve 가 아닌 리뷰. 사람 계정은 레포 권한이 write 이상인
#   계정이다(`human_review.sh` 와 같다 — 봇은 권한 조회가 404 라 빠진다). Approve 는 머지로 이어지므로 까닭이 아니다
# - 머지되지 않음: Approve 됐는데(`reviewDecision` `APPROVED`) 머지되지 않았다. 검사가 실행 중이거나 GitHub 이
#   아직 계산 중(`UNKNOWN`)이면 기다린다. Approve 직후에는 GitHub 이 머지하기 전의 상태가 한 번 보일 수 있어서
#   두 번 잇달아 보여야 끝난다
# - 조회 실패: 조회가 5번 잇달아 실패했다(네트워크 · 봇 키)
# - 이미 기다림: 같은 PR 을 기다리는 이 스크립트가 실행 중이다. 세션 시작 안내(`bot_session.sh`)가 auto-merge 가
#   켜진 PR 마다 이 스크립트를 켜라고 하므로, 컴팩션이나 재시작 뒤에 같은 PR 을 두 번 기다리지 않게 한다. 잠금은
#   `<git 공통 디렉터리>/ai-kit-wait/<PR>` 에 프로세스 번호로 둔다. 끝나도 지우지 않는다 — 그 번호의 프로세스가
#   이 스크립트가 아니면 잠금을 무시한다
#
# **토큰.** 봇 설치 토큰은 한 시간이면 끝난다. 이 스크립트 안의 gh 는 막기 훅(`bot_guard.sh`)을 거치지 않으므로
# 조회마다 봇 디렉터리(`GH_CONFIG_DIR`)의 `expires` 를 보고, 10분 안에 끝나면 `bot_token.sh` 로 새로 받는다. 토큰은
# 출력하지 않는다.
exec python3 - "$0" "$@" <<'PY'
import datetime, json, os, re, subprocess, sys, time

here = os.path.dirname(os.path.abspath(sys.argv[1]))
args = sys.argv[2:]
NEXT = "(merge-pr 3절 「대기 스크립트가 끝나면」)"


def done(code, line):
    print(line)
    sys.exit(code)


pr, repo, i = None, None, 0
while i < len(args):
    if args[i] in ('-R', '--repo') and i + 1 < len(args):
        repo, i = args[i + 1], i + 2
        continue
    if not re.match(r'^\d+$', args[i]) or pr is not None:
        pr = None
        break
    pr, i = args[i], i + 1
if pr is None:
    done(2, "사용: wait_merge.sh <PR 번호> [-R <owner/repo>]")

interval = float(os.environ.get('WAIT_MERGE_INTERVAL') or 60)
env = dict(os.environ)
if repo:
    env['GH_REPO'] = repo              # `gh api` 의 {owner}/{repo} 를 이 레포로 푼다
R = ['-R', repo] if repo else []
FIELDS = ('state,mergeCommit,baseRefName,autoMergeRequest,headRefOid,reviewDecision,mergeStateStatus,'
          'statusCheckRollup,comments,reviews')

# 같은 PR 을 기다리는 스크립트가 실행 중이면 끝낸다
common = subprocess.run(['git', 'rev-parse', '--git-common-dir'], capture_output=True, text=True)
lock = None
if common.returncode == 0:
    lockdir = os.path.join(os.path.abspath(common.stdout.strip()), 'ai-kit-wait')
    lock = os.path.join(lockdir, (re.sub(r'[^A-Za-z0-9_.-]', '_', repo) + '-' if repo else '') + pr)
    try:
        other = int(open(lock).read().strip())
        cmd = subprocess.run(['ps', '-o', 'command=', '-p', str(other)], capture_output=True, text=True).stdout
        if other != os.getpid() and 'wait_merge' in cmd:
            done(0, "이미 기다림: PR #%s 을 기다리는 대기 스크립트(프로세스 %d)가 실행 중이다. 그 스크립트가 끝날 때 "
                    "세션이 깨어난다." % (pr, other))
    except (OSError, ValueError):
        pass
    os.makedirs(lockdir, exist_ok=True)
    with open(lock, 'w') as fh:
        fh.write('%d\n' % os.getpid())


class GhError(Exception):
    pass


def gh(*a):
    try:
        r = subprocess.run(['gh', *a], capture_output=True, text=True, env=env, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GhError(str(e))
    if r.returncode:
        raise GhError((r.stderr.strip().splitlines() or ['gh 실패'])[-1])
    try:
        return json.loads(r.stdout)
    except ValueError:
        raise GhError('gh 출력이 JSON 이 아니다')


def refresh():
    """봇 토큰이 10분 안에 끝나면 새로 받는다. 실패하면 까닭을, 아니면 ''을 돌려준다."""
    cfg = os.environ.get('GH_CONFIG_DIR')
    try:
        until = open(os.path.join(cfg, 'expires')).read().strip() if cfg else ''
        end = datetime.datetime.strptime(until, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except (OSError, ValueError):
        return ''
    if (end - datetime.datetime.now(datetime.timezone.utc)).total_seconds() >= 600:
        return ''
    try:
        r = subprocess.run(['bash', os.path.join(here, 'bot_token.sh')], capture_output=True, text=True,
                           env=env, timeout=120)
    except subprocess.TimeoutExpired:
        return '봇 토큰을 새로 받다가 시간이 다 됐다'
    return (r.stdout.strip().splitlines() or [''])[0] if r.returncode else ''


perms = {}


def person(login):
    """레포 권한이 write 이상인 계정인가. 봇 · 없는 계정은 권한 조회가 404 다."""
    if login not in perms:
        try:
            perms[login] = gh('api', 'repos/{owner}/{repo}/collaborators/%s/permission' % login).get('permission')
        except GhError as e:
            if 'HTTP 404' not in str(e):
                raise
            perms[login] = None
    return perms[login] in ('admin', 'write')


def items(v):
    """(id, 글쓴이, 무엇이 달렸나, Approve 인가) — 코멘트와 리뷰"""
    for c in v.get('comments') or []:
        yield c['id'], (c.get('author') or {}).get('login'), '코멘트가 달렸다(%s)' % (c.get('url') or ''), False
    for r in v.get('reviews') or []:
        yield (r['id'], (r.get('author') or {}).get('login'), '리뷰가 달렸다(%s)' % r.get('state'),
               r.get('state') == 'APPROVED')


def checks(v):
    """(실행 중인 검사가 있나, 실패한 검사 이름들)"""
    pending, failed = False, []
    for c in v.get('statusCheckRollup') or []:
        if c.get('__typename') == 'StatusContext':
            s = c.get('state')
            pending |= s in ('PENDING', 'EXPECTED')
            if s in ('FAILURE', 'ERROR'):
                failed.append(c.get('context') or '?')
        else:
            pending |= c.get('status') != 'COMPLETED'
            if c.get('conclusion') in ('FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'):
                failed.append(c.get('name') or '?')
    return pending, failed


STATES = {
    'BEHIND': "브랜치가 base 보다 뒤처졌다",
    'DIRTY': "base 와 충돌한다",
    'BLOCKED': "필요한 검사가 실패했거나 보고되지 않았거나, 풀리지 않은 리뷰 대화가 있다",
    'CLEAN': "머지할 수 있는 상태인데 GitHub 이 머지하지 않았다",
}
head, seen = None, None
fails, approved, why = 0, 0, ''
while True:
    tok = refresh()
    try:
        v = gh('pr', 'view', pr, *R, '--json', FIELDS)
        if v['state'] == 'MERGED':
            done(0, "머지됨: PR #%s 이 %s 에 머지됐다(%s). 다른 일을 시작하기 전에 「다음 일」 창을 먼저 묻는다%s."
                 % (pr, v.get('baseRefName'), ((v.get('mergeCommit') or {}).get('oid') or '')[:7], NEXT))
        if v['state'] == 'CLOSED':
            done(1, "닫힘: PR #%s 이 머지되지 않고 닫혔다. 무엇이 일어났는지 사람에게 알린다%s." % (pr, NEXT))
        if head is None:
            head, seen = v['headRefOid'], {k for k, *_ in items(v)}
        if v['headRefOid'] != head:
            done(1, "head 바뀜: PR #%s 의 head 가 %s 에서 %s 로 바뀌었다. 누가 푸시했는지와 무엇이 필요한지 사람에게 "
                    "알린다%s." % (pr, head[:7], v['headRefOid'][:7], NEXT))
        if not v.get('autoMergeRequest'):
            done(1, "auto-merge 꺼짐: PR #%s 의 auto-merge 가 꺼졌다. 무엇이 필요한지 사람에게 알린다%s." % (pr, NEXT))
        for k, login, what, approve in items(v):
            if k in seen:
                continue
            if not approve and login and person(login):
                done(1, "사람의 글: PR #%s 에 %s 의 %s. 읽고 무엇이 필요한지 사람에게 알린다%s."
                     % (pr, login, what, NEXT))
            seen.add(k)
        pending, failed = checks(v)
        state = v.get('mergeStateStatus')
        if v.get('reviewDecision') != 'APPROVED' or pending or state == 'UNKNOWN':
            approved = 0
        else:
            approved += 1
            if approved >= 2:
                done(1, "머지되지 않음: PR #%s 은 Approve 됐는데 머지되지 않았다(mergeStateStatus %s: %s%s). 그 상태와 "
                        "무엇이 필요한지 사람에게 알린다%s."
                     % (pr, state, STATES.get(state, "GitHub 의 상태 값 그대로다"),
                        ". 실패한 검사: " + ", ".join(failed) if failed else '', NEXT))
    except GhError as e:
        fails, why = fails + 1, str(e) + (". " + tok if tok else '')
    except (KeyError, TypeError, AttributeError):
        fails, why = fails + 1, "GitHub 응답의 모양이 예상과 다르다"
    else:
        fails = 0
    if fails >= 5:
        done(1, "조회 실패: PR #%s 을 5번 잇달아 조회하지 못했다(%s). 네트워크나 봇 키를 고친 뒤 이 스크립트를 다시 "
                "켠다%s." % (pr, why, NEXT))
    time.sleep(interval)
PY
