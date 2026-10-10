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
# 다른 세션이 맡은 일은 둘로 안다. 열린 PR 은 닫는 이슈와 본문의 `Refs #N` 만 뺀다 — 본문은 근거로 다른 이슈를
# 들기도 해서, 다 빼면 그 PR 이 열려 있는 동안 근거로 든 이슈가 후보에서 빠진다. PR 이 없는 다른 worktree 의
# 브랜치는 기본 브랜치에 없는 커밋의 메시지에 나오는 `#N` 을 꼴을 가리지 않고 모두 뺀다 — PR 이 없으면 커밋
# 메시지가 유일한 단서이고, 닫는 키워드 없이 번호를 적기도 한다. 번호가 없는 브랜치는 이름을 그대로 낸다. 이
# 스크립트를 실행한 worktree 는 세션 자신의 일이라 내지 않는다. 같은 레포의 다른 clone 은 보이지 않는다.
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


def gh_list(kind, fields):
    r = run(['gh', kind, 'list', '--state', 'open', '--limit', str(LIMIT), '--json', fields])
    if r.returncode != 0:
        err = (r.stderr.strip().splitlines() or ['(출력 없음)'])[0]
        die('열린 %s 을 받지 못했다: %s' % ('이슈' if kind == 'issue' else 'PR', err))
    items = json.loads(r.stdout or '[]')
    if len(items) >= LIMIT:
        die('열린 %s 이 한도(%d)만큼 왔다 — 잘렸을 수 있어 이 목록으로 고르지 않는다'
            % ('이슈' if kind == 'issue' else 'PR', LIMIT))
    return items


def nums(text):
    return [int(n) for n in re.findall(r'#(\d+)', text or '')]


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
    refs = [int(n) for n in re.findall(r'(?im)\brefs?:?[ \t]+#(\d+)', p.get('body') or '')]
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
    die('worktree 목록을 받지 못했다: %s' % (wt.stderr.strip().splitlines() or [''])[0])
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
        die('%s 의 커밋을 읽지 못했다: %s' % (name, (log.stderr.strip().splitlines() or [''])[0]))
    if branch == default and not log.stdout.strip():
        continue
    found = sorted(set(nums(log.stdout)))
    for n in found:
        drop.append((n, 'worktree %s 의 커밋' % name))
    rows.append('%s\t%s\tPR 없음\t커밋이 말하는 번호 %s' % (path, name, ' '.join('#%d' % n for n in found) or '없음'))
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
