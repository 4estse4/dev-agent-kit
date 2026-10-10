#!/usr/bin/env bash
# 「다음 일」을 고를 때 받는 목록 — 열린 이슈 전부 · 열린 PR · 다른 worktree 와, 그중 다른 세션이 맡아 후보에서 뺄
# 열린 이슈를 출력한다. 필요: python3 · git · gh
#
#     bash .claude/hooks/backlog.sh
#
# **왜.** 「다음 일」 보기가 하던 묶음의 다음 차례에서만 나와, 열린 이슈 가운데 먼저 할 것이 보기에 오르지 않았다.
# 그래서 고를 때마다 열린 이슈 전체를 다시 받는다. 순서는 이 스크립트가 아니라 세션이 `merge-pr` 의 「다음 일」
# 문단대로 정한다. 이 스크립트는 받아 오기만 한다.
#
# 다른 세션이 맡은 일은 두 곳에서 알아낸다. 열린 PR 은 닫는 이슈와 본문의 `Refs #N` 만 뺀다 — 본문은 근거로
# 다른 이슈를 들기도 해서, 다 빼면 그 PR 이 열려 있는 동안 근거로 든 이슈가 후보에서 빠진다. PR 이 없는 다른 worktree 의
# 브랜치도 같다 — 기본 브랜치에 없는 커밋의 메시지에서 줄 머리의 닫는 키워드(Closes · Fixes · Resolves 꼴)나 `Refs` 가
# 붙은 번호만 빼고, 그 밖의 번호는 그 worktree 줄에 근거로 든 번호로 보이기만 한다. 한때 번호를 모두 빼서, 다른 세션이 계획
# 커밋에서 순서의 근거로만 든 이슈가 후보에서 빠졌다. 브랜치의 커밋 어디에도 그런 키워드가 없으면 맡은 이슈를 알 단서가
# 번호뿐이라 번호를 모두 뺀다. 번호가 없는 브랜치는 이름을 그대로 낸다.
#
# 빼지 않는 것: 열린 PR 은 없고 팁이 머지되거나 닫힌 PR 의 head 에 들어 있는 브랜치는 끝난 일이라 그 커밋의 번호를
# 빼지 않는다 — 스쿼시 머지에서는 그 커밋이 기본 브랜치의 조상이 되지 않아 「기본 브랜치에 없는 커밋」으로 나온다.
# 이름만 같고 팁이 그 head 에 없으면(브랜치 이름을 다시 써서 새 일을 한다) 끝난 일이 아니다. 기본 브랜치에
# 없는 커밋이 하나도 없는 detach worktree(정리를 마친 worktree)와 기본 브랜치의 worktree 는 내지 않는다. 이
# 스크립트를 실행한 worktree 는 세션 자신의 일이라 내지 않는다. 같은 레포의 다른 clone 에서 PR 없이 하는 일은
# 보이지 않는다.
#
# `gh issue list` · `gh pr list` 는 기본으로 30건만 받는다. 한도를 크게 주고, 받은 수가 한도에 닿으면 잘렸을 수
# 있어 실패한다.
#
# 종료 코드: 0 출력함 · 1 조회가 실패했거나 받은 목록이 잘렸을 수 있거나 기본 브랜치를 모름
set -u
python3 - <<'PY'
import json, os, re, subprocess, sys

LIMIT = 1000


def die(msg):
    print('!! ' + msg)
    sys.exit(1)


def run(args):
    return subprocess.run(args, capture_output=True, text=True)


def first_line(text):
    return (text.strip().splitlines() or ['(출력 없음)'])[0]


def gh_list(kind, fields):
    # 조사가 앞말에 맞게 이름마다 따로 둔다: (목적격, 주격)
    obj, subj = ('이슈를', '이슈가') if kind == 'issue' else ('PR 을', 'PR 이')
    r = run(['gh', kind, 'list', '--state', 'open', '--limit', str(LIMIT), '--json', fields])
    if r.returncode != 0:
        die('열린 %s 받지 못했다: %s' % (obj, first_line(r.stderr)))
    items = json.loads(r.stdout or '[]')
    if len(items) >= LIMIT:
        die('열린 %s 한도(%d)만큼 왔다 — 잘렸을 수 있어 이 목록으로 고르지 않는다' % (subj, LIMIT))
    return items


def finished_pr(branch, tip):
    """열린 PR 이 없는 브랜치의 팁이 머지되거나 닫힌 PR 의 head 에 들어 있으면 (번호, 상태) 를, 아니면 None 을
    낸다. 이름만 보면 머지된 PR 의 브랜치 이름을 다시 써서 새 일을 하는 worktree 도 끝난 일로 본다"""
    r = run(['gh', 'pr', 'list', '--state', 'all', '--head', branch, '--limit', '10',
             '--json', 'number,state,headRefOid'])
    if r.returncode != 0:
        die('%s 브랜치의 PR 을 받지 못했다: %s' % (branch, first_line(r.stderr)))
    done = [p for p in json.loads(r.stdout or '[]') if p.get('state') in ('MERGED', 'CLOSED')]
    for p in sorted(done, key=lambda p: -p['number']):
        oid = p.get('headRefOid') or ''
        # 그 head 가 이 레포에 없으면 is-ancestor 가 실패한다 — 끝난 일로 보지 않는다(번호를 빼는 쪽)
        if oid and (oid == tip or run(['git', 'merge-base', '--is-ancestor', tip, oid]).returncode == 0):
            return p['number'], '머지됨' if p['state'] == 'MERGED' else '닫힘'
    return None


def nums(text):
    return [int(n) for n in re.findall(r'#(\d+)', text or '')]


# 키워드 뒤에 `,` · `and` 로 이은 번호를 모두 읽고, 줄을 넘지 않는다. `owner/repo#N` 은 읽지 않는다 — 다른 레포의 번호를
# 이 레포의 이슈로 빼게 된다.
LIST = r'(#\d+(?:[ \t]*(?:,|\band\b)[ \t]*#\d+)*)'
# 커밋 메시지에서는 `Refs` 나 닫는 키워드(Closes · Fixes · Resolves 꼴)로 시작하는 줄(앞 공백만 허용)만 읽는다.
# 커밋 본문은 다른 일을 설명하며 산문이나 인용 속에 키워드를 적기도 한다. `merge-pr` 가 스쿼시 커밋에서 키워드를 찾는
# 식은 무엇이 닫히는지를 보므로 줄 어디서든 찾고 번호를 하나씩 읽는데, 여기서는 누가 그 이슈를 맡았는지를 본다.
REFS = r'(?im)^[ \t]*refs?:?[ \t]+' + LIST
CLOSES = r'(?im)^[ \t]*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \t]+' + LIST
# PR 본문의 `Refs` 는 줄 어디서든 읽는다. PR 본문은 그 PR 이 맡은 이슈를 「이 PR 은 이슈 #N 을 닫지 않는다. Refs #N.」 ·
# 「(Refs #N)」처럼 문장이나 괄호 안에 적는다. 줄 머리만 보면 그 꼴을 놓쳐 열린 PR 이 맡은 이슈가 후보에 다시 오른다.
BODY_REFS = r'(?i)\brefs?:?[ \t]+' + LIST


def listed(pattern, text):
    return [int(n) for span in re.findall(pattern, text or '') for n in re.findall(r'#(\d+)', span)]


def keyed(text):
    return listed(REFS, text) + listed(CLOSES, text)


top = run(['git', 'rev-parse', '--show-toplevel'])
if top.returncode != 0:
    die('git 레포 안에서 실행하지 않았다')
here = os.path.realpath(top.stdout.strip())
head = run(['git', 'symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD'])
base = head.stdout.strip()
if head.returncode != 0 or not base:
    die('origin 의 기본 브랜치를 모른다(origin/HEAD 가 없다) — `git remote set-head origin --auto` 로 정한다')

issues = gh_list('issue', 'number,title,updatedAt,comments')
prs = gh_list('pr', 'number,title,headRefName,closingIssuesReferences,body')
open_issues = {i['number'] for i in issues}
drop = []  # (번호, 어디서)

print('== 열린 이슈 %d건' % len(issues))
for i in issues:
    print('#%d\t%s\t코멘트 %d\t%s' % (i['number'], (i.get('updatedAt') or '')[:10], len(i.get('comments') or []), i['title']))

print('== 열린 PR %d건' % len(prs))
pr_by_branch = {}
for p in prs:
    pr_by_branch[p['headRefName']] = p['number']
    closing = [c['number'] for c in p.get('closingIssuesReferences') or []]
    refs = listed(BODY_REFS, p.get('body'))
    for n in closing:
        drop.append((n, 'PR #%d 의 닫는 이슈' % p['number']))
    for n in refs:
        drop.append((n, 'PR #%d 의 Refs' % p['number']))
    print('#%d\t%s\t닫는 이슈 %s\tRefs %s\t%s' % (
        p['number'], p['headRefName'],
        ' '.join('#%d' % n for n in closing) or '없음',
        ' '.join('#%d' % n for n in refs) or '없음', p['title']))

wt = run(['git', 'worktree', 'list', '--porcelain'])
if wt.returncode != 0:
    die('worktree 목록을 받지 못했다: %s' % first_line(wt.stderr))
trees, cur = [], {}
for line in wt.stdout.splitlines() + ['']:
    if not line:
        if cur:
            trees.append(cur)
        cur = {}
        continue
    key, _, val = line.partition(' ')
    cur[key] = val
rows = []
default = base.split('/', 1)[1] if '/' in base else base
for t in trees:
    path = t.get('worktree', '')
    if 'prunable' in t or os.path.realpath(path) == here:
        continue
    branch = t.get('branch', '').replace('refs/heads/', '', 1)
    ref = branch or t.get('HEAD', '')
    name = branch or '(detached %s)' % t.get('HEAD', '')[:7]
    if branch in pr_by_branch:
        rows.append('%s\t%s\tPR #%d' % (path, name, pr_by_branch[branch]))
        continue
    log = run(['git', 'log', '%s..%s' % (base, ref), '--format=%B'])
    if log.returncode != 0:
        die('%s 의 커밋을 읽지 못했다: %s' % (name, first_line(log.stderr)))
    if (not branch or branch == default) and not log.stdout.strip():
        continue
    done = finished_pr(branch, t.get('HEAD', '')) if branch else None
    if done:
        rows.append('%s\t%s\tPR #%d %s' % (path, name, done[0], done[1]))
        continue
    found = sorted(set(nums(log.stdout)))
    taken = sorted(set(keyed(log.stdout)))
    if taken:
        why = 'worktree %s 의 Refs · 닫는 키워드' % name
        note = ''
    else:
        taken, why = found, 'worktree %s 의 커밋(닫는 키워드 · Refs 없음)' % name
        note = '(닫는 키워드 · Refs 가 없어 커밋이 말하는 번호를 모두 뺀다)' if found else ''
    cited = [n for n in found if n not in taken]
    for n in taken:
        drop.append((n, why))
    rows.append('%s\t%s\tPR 없음\t빼는 번호 %s%s\t근거로 든 번호 %s' % (
        path, name, ' '.join('#%d' % n for n in taken) or '없음', note,
        ' '.join('#%d' % n for n in cited) or '없음'))
print('== 다른 worktree %d개' % len(rows))
for r in rows:
    print(r)

print('== 후보에서 뺄 열린 이슈')
seen = {}
for n, where in drop:
    if n in open_issues:
        seen.setdefault(n, []).append(where)
for n in sorted(seen):
    print('#%d\t%s' % (n, ' · '.join(dict.fromkeys(seen[n]))))
PY
