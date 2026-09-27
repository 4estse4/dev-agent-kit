#!/usr/bin/env bash
# PR 의 3.5 코멘트(`### N라운드 코멘트를 읽고 사람이 정한 것`)마다 사람의 👍 가 있는지 본다.
# 필요: python3 · gh
#
#     bash .claude/hooks/answer_approvals.sh <PR 번호> [-R <owner/repo>]
#
# 3.5 코멘트마다 `✓ <URL> — <계정> <시각>` 이나 `✗ <URL> — <까닭>` 한 줄을 출력한다.
# 종료 코드: 모두 👍 가 있으면 0, 없는 것이 있으면 1, 판정 못 하면 2.
# `--json` 을 앞에 두면 (사람) 인용을 확인하는 훅이 읽는 JSON 을 출력한다.
#
# **레포에 봇 설정(`.claude/bot.json`)이 있을 때만 👍 를 본다.** 봇 설정이 있으면 세션은 봇
# 계정으로 글을 올리고, 사람은 자기 계정으로 3.5 코멘트에 👍 를 단다. 그래서 GitHub 에서 3.5
# 코멘트의 답을 사람이 승인했는지가 보인다. 봇 설정이 없으면 세션과 사람이 한 계정이라
# 👍 가 아무것도 보여 주지 않으므로 보지 않는다(종료 0).
#
# **승인으로 인정하는 👍.** 넷을 모두 채워야 한다.
# - `+1` 리액션이다
# - 단 계정이 사람 계정이다. 계정이 없는 리액션은 인정하지 않고, 계정 이름이 오면 아래 권한으로
#   거른다 — 봇 계정의 레포 권한은 none 이다
# - 그 계정의 레포 권한이 write 이상이다(`collaborators/<계정>/permission` 의 admin · write.
#   maintain 은 write 로 온다). 누구나 👍 를 달 수 있어서다
# - 코멘트를 마지막으로 고친 시각(`lastEditedAt`) 뒤에 달았다. GitHub 은 코멘트를 고쳐도 달린
#   리액션을 지우지 않는다. 고친 뒤의 글을 사람이 승인했는지는 고친 뒤의 👍 만 말한다
#
# **판정 못 하면 2 로 끝낸다.** 코멘트나 권한을 못 읽으면 승인이 있는지 모른다. 모르는 것을
# 승인으로 처리하지 않는다.
exec python3 - "$@" <<'PY'
import json, os, re, subprocess, sys

ANSWER = re.compile(r'^\s*### .*라운드 코멘트를 읽고 사람이 정한 것')
QUERY = '''query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    comments(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { url body lastEditedAt
        reactions(content: THUMBS_UP, first: 100) { totalCount nodes { createdAt user { login } } } } } } } }'''

args = sys.argv[1:]
as_json = bool(args) and args[0] == '--json'
if as_json:
    args = args[1:]
pr, repo = None, None
i = 0
while i < len(args):
    if args[i] in ('-R', '--repo') and i + 1 < len(args):
        repo = args[i + 1]
        i += 2
        continue
    if re.match(r'^\d+$', args[i]) and pr is None:
        pr = args[i]
    else:
        pr = None
        break
    i += 1


def stop(code, why):
    print(json.dumps({"error": why}, ensure_ascii=False) if as_json else why)
    sys.exit(code)


if pr is None:
    stop(2, "사용: answer_approvals.sh [--json] <PR 번호> [-R <owner/repo>]")

env = dict(os.environ)
if repo:
    env['GH_REPO'] = repo


class GhError(Exception):
    pass


def gh(*a):
    try:
        r = subprocess.run(['gh', *a], capture_output=True, text=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise GhError(str(e))
    if r.returncode:
        raise GhError((r.stderr.strip().splitlines() or ['gh 실패'])[-1])
    try:
        return json.loads(r.stdout)
    except ValueError:
        raise GhError('gh 출력이 JSON 이 아니다')


top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
root = top.stdout.strip() if top.returncode == 0 else os.getcwd()
bot = os.path.isfile(os.path.join(root, '.claude', 'bot.json'))

if not bot:
    if not as_json:
        stop(0, "봇 설정(.claude/bot.json)이 없어 👍 를 확인하지 않는다.")
    try:
        bodies = gh('pr', 'view', pr, *(['-R', repo] if repo else []),
                    '--json', 'comments', '--jq', '[.comments[].body]')
    except GhError as e:
        stop(2, "판정 못 함: PR 코멘트를 읽다가 실패했다(gh: %s)." % e)
    if not isinstance(bodies, list):
        stop(2, "판정 못 함: PR 코멘트를 읽지 못했다.")
    print(json.dumps({"bot": False, "answers": [
        {"url": None, "approved": None, "why": "", "body": b}
        for b in bodies if isinstance(b, str) and ANSWER.match(b)]}, ensure_ascii=False))
    sys.exit(0)

perms = {}


def permission(login):
    if login not in perms:
        try:
            perms[login] = gh('api', 'repos/{owner}/{repo}/collaborators/%s/permission' % login
                              ).get('permission')
        except GhError as e:
            if 'HTTP 404' not in str(e):       # 없는 계정 · 봇은 404 다. 그 밖의 실패는 판정 못 함
                raise
            perms[login] = None
    return perms[login]


answers = []
try:
    pages = gh('api', 'graphql', '--paginate', '--slurp', '-F', 'owner={owner}', '-F', 'name={repo}',
               '-F', 'number=' + pr, '-f', 'query=' + QUERY)
    nodes = []
    for p in pages:
        nodes += p['data']['repository']['pullRequest']['comments']['nodes']
    for n in nodes:
        body = n.get('body') or ''
        if not ANSWER.match(body):
            continue
        edited = n.get('lastEditedAt') or ''
        got = n['reactions']
        if got['totalCount'] > len(got['nodes']):
            stop(2, "판정 못 함: %s 의 👍 가 한 번에 읽는 수보다 많다." % n['url'])
        ok, notes = None, []
        for r in got['nodes']:
            who = (r.get('user') or {}).get('login')
            if not who:
                notes.append("계정을 알 수 없는 👍(봇)")
            elif edited and r['createdAt'] <= edited:
                # 리액션은 한 사람당 한 종류에 하나라, 한 번 누르면 떼어지기만 한다
                notes.append("%s 의 👍 는 코멘트를 고치기 전에 달았다. 👍 를 떼고 다시 단다" % who)
            elif permission(who) not in ('admin', 'write'):
                notes.append("%s 는 쓰기 권한이 없다(%s)" % (who, permission(who) or '없음'))
            else:
                ok = "%s %s" % (who, r['createdAt'])
                break
        answers.append({"url": n['url'], "approved": bool(ok), "body": body,
                        "why": ok or (" · ".join(notes) if notes else "👍 가 없다")})
except GhError as e:
    stop(2, "판정 못 함: 3.5 코멘트의 👍 를 읽다가 실패했다(gh: %s)." % e)
except (KeyError, TypeError):
    stop(2, "판정 못 함: GitHub 응답의 모양이 예상과 다르다.")

if as_json:
    print(json.dumps({"bot": True, "answers": answers}, ensure_ascii=False))
    sys.exit(0)
if not answers:
    stop(0, "3.5 코멘트가 없다.")
for a in answers:
    print("%s %s — %s" % ('✓' if a['approved'] else '✗', a['url'], a['why']))
sys.exit(0 if all(a['approved'] for a in answers) else 1)
PY
