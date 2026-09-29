#!/usr/bin/env bash
# 봇 설정(`.claude/bot.json`)이 있는 레포에서 PR 의 사람 계정 코멘트와 사람의 Approve 를 읽는다.
# 필요: python3 · gh
#
#     bash .claude/hooks/human_review.sh sources <PR 번호> [-R <owner/repo>]
#     bash .claude/hooks/human_review.sh approved <PR 번호> [-R <owner/repo>]
#
# 봇 설정이 있으면 세션은 봇 계정으로 쓰고 사람은 자기 계정으로 쓴다. 그래서 GitHub 이 기록한 글쓴이로
# 사람의 결정과 승인이 구분된다. 봇 설정이 없으면 세션과 사람이 한 계정이라 글쓴이로 구분하지 못한다.
#
# **sources** — (사람) 인용을 확인하는 훅(`round_comment_quotes.sh`)이 대조할 원본을 JSON 으로 낸다:
# `{"bot": true|false, "comments": [{"url", "author", "body"}]}`. 원본은 사람 계정 코멘트다. 글쓴이의 레포
# 권한(`collaborators/<계정>/permission`)이 write 이상이고, 글쓴이가 아닌 계정이 마지막으로 고치지 않은
# 코멘트다. 봇 계정은 권한 조회가 404(사용자가 아니다)라 빠진다. 두 리뷰가 결정을 고르는
# `authorAssociation`(OWNER · MEMBER · COLLABORATOR)으로 거르지 않는 것은, MEMBER 가 레포 권한과 상관없이
# 조직 구성원이면 붙어서다. 레포에 쓰기 권한이 있는 계정은 남의 코멘트도 고칠 수 있어서(GitHub 문서의 역할
# 표: "Edit and delete anyone's comments on commits, pull requests, and issues" 는 write 이상) 봇이 고친
# 사람 코멘트는 사람의 글이 아니다. 코멘트의 어느 글자를 원본으로 쓸지는 훅이 정한다. 봇 설정이 없으면 훅이
# 이 판정을 부르지 않고 (사람) 인용을 막는다 — 세션과 사람이 한 계정이라 글쓴이로 사람의 글을 가려낼 수 없다.
#
# **approved** — 지금 head 에 사람의 Approve 가 있는지 본다. `merge-pr` 2절이 auto-merge 를 켤 수 없을 때
# 부른다(켤 수 있으면 Approve 가 달릴 때 GitHub 이 머지한다). 있으면 `✓ …` 와
# 종료 0, 없으면 `✗ …` 와 종료 1 이다. 인정하는 Approve 는 둘을 모두 채운다.
# - 리뷰한 계정의 레포 권한이 write 이상이다(`collaborators/<계정>/permission` 의 admin · write.
#   maintain 은 write 로 온다). 브랜치 보호가 필요 승인 수로 세는 것도 쓰기 권한자의 Approve 다
# - 그 계정의 마지막 리뷰(Comment 를 뺀 것)가 Approve 이고, 그 리뷰가 가리키는 커밋이 지금 head 다.
#   Dismiss 된 리뷰는 없는 것이다
# 쓰기 권한자 가운데 마지막 리뷰가 Request changes 인 사람이 있으면 Approve 가 있어도 종료 1 이다. GitHub 이
# 브랜치 보호의 필요 승인 수로 계산한 `reviewDecision` 이 `REVIEW_REQUIRED`(승인이 모자람)나
# `CHANGES_REQUESTED` 여도 종료 1 이다 — 리뷰하는 사람이 여럿이라 필요 승인 수를 올린 레포에서 한 사람의
# Approve 로 머지를 시도하면 GitHub 이 거부한다. 필요 승인 수가 0 이면 `reviewDecision` 은 비어 있다.
# 봇 설정이 없으면 판정하지 않는다(종료 2) — PR 작성자인 사람이 자기 PR 을 Approve 할 수 없다.
#
# **판정 못 하면 2 로 끝낸다.** 코멘트 · 리뷰 · 권한을 못 읽으면 사람의 결정이 무엇인지 모른다. 모르는
# 것을 사람의 결정으로 처리하지 않는다.
exec python3 - "$@" <<'PY'
import json, os, re, subprocess, sys

QUERY = '''query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) {
    comments(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { url body author { login } editor { login } } } } } }'''

args = sys.argv[1:]
mode = args[0] if args else ''
pr, repo = None, None
i = 1
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
    print(json.dumps({"error": why}, ensure_ascii=False) if mode == 'sources' else why)
    sys.exit(code)


if mode not in ('sources', 'approved') or pr is None:
    stop(2, "사용: human_review.sh sources|approved <PR 번호> [-R <owner/repo>]")

env = dict(os.environ)
if repo:
    env['GH_REPO'] = repo
R = ['-R', repo] if repo else []       # `gh pr view` 에는 인자로도 준다


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


if mode == 'sources':
    try:
        pages = gh('api', 'graphql', '--paginate', '--slurp', '-F', 'owner={owner}', '-F', 'name={repo}',
                   '-F', 'number=' + pr, '-f', 'query=' + QUERY)
        comments = []
        for p in pages:
            for n in p['data']['repository']['pullRequest']['comments']['nodes']:
                who = (n.get('author') or {}).get('login')
                editor = (n.get('editor') or {}).get('login')
                if not who:
                    continue
                if editor and editor != who:
                    comments.append({"url": n['url'], "author": who, "body": None,
                                     "why": "%s 가 고친 코멘트다" % editor})
                    continue
                if permission(who) not in ('admin', 'write'):
                    continue
                comments.append({"url": n['url'], "author": who, "body": n.get('body') or ''})
    except GhError as e:
        stop(2, "판정 못 함: PR 코멘트나 글쓴이의 권한을 읽다가 실패했다(gh: %s)." % e)
    except (KeyError, TypeError):
        stop(2, "판정 못 함: GitHub 응답의 모양이 예상과 다르다.")
    print(json.dumps({"bot": bot, "comments": comments}, ensure_ascii=False))
    sys.exit(0)

if not bot:
    stop(2, "봇 설정(.claude/bot.json)이 없어 Approve 를 판정하지 않는다. 세션과 사람이 한 계정이라 PR "
            "작성자인 사람이 자기 PR 을 Approve 할 수 없다. 킷은 봇과 함께 쓴다 — 봇을 켜는 법은 "
            "docs/process/kit-guide.md 의 「봇 계정과 사람의 승인」 절에 있다.")

try:
    view = gh('pr', 'view', pr, *R, '--json', 'headRefOid,reviewDecision')
    head, decision = view['headRefOid'], view.get('reviewDecision') or ''
    pages = gh('api', '--paginate', '--slurp', 'repos/{owner}/{repo}/pulls/%s/reviews' % pr)
    last = {}
    for page in pages:
        for r in page:
            who = (r.get('user') or {}).get('login')
            if who and r.get('state') in ('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'):
                last[who] = r
    ok, notes, blocks = [], [], []
    for who, r in last.items():
        if r['state'] == 'DISMISSED':
            continue
        if permission(who) not in ('admin', 'write'):
            if r['state'] == 'APPROVED':
                notes.append("%s 는 쓰기 권한이 없어 그 Approve 를 세지 않는다(%s)" % (who, permission(who) or '없음'))
            continue
        if r['state'] == 'CHANGES_REQUESTED':
            blocks.append("%s 가 Request changes 를 남겼다(%s)" % (who, r.get('submitted_at')))
        elif r.get('commit_id') == head:
            ok.append("%s 가 지금 head %s 를 Approve 했다(%s)" % (who, head[:7], r.get('submitted_at')))
        else:
            notes.append("%s 의 Approve 는 이전 커밋 %s 에 대한 것이다. 지금 head %s 에 다시 Approve 를 받는다"
                         % (who, (r.get('commit_id') or '')[:7], head[:7]))
    if decision == 'REVIEW_REQUIRED':
        blocks.append("브랜치 보호가 요구하는 승인이 모자라다(GitHub 의 reviewDecision: REVIEW_REQUIRED). 필요 승인 "
                      "수가 모자라거나, 승인한 사람이 이 PR 브랜치에 마지막으로 푸시해 그 Approve 가 세어지지 "
                      "않는다(마지막 푸시 승인). 뒤의 것이면 세션이 다시 푸시한 뒤 Approve 를 다시 받는다")
    elif decision == 'CHANGES_REQUESTED':
        blocks.append("GitHub 이 이 PR 을 Request changes 로 판정했다(reviewDecision: CHANGES_REQUESTED)")
except GhError as e:
    stop(2, "판정 못 함: PR 의 리뷰나 권한을 읽다가 실패했다(gh: %s)." % e)
except (KeyError, TypeError):
    stop(2, "판정 못 함: GitHub 응답의 모양이 예상과 다르다.")

for line in ok:
    print("✓ " + line)
for line in blocks + notes:
    print("✗ " + line)
if not ok:
    print("✗ 지금 head %s 에 쓰기 권한이 있는 사람 계정의 Approve 가 없다" % head[:7])
sys.exit(0 if ok and not blocks else 1)
PY
