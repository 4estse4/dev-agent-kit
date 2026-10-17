#!/usr/bin/env bash
# PreToolUse(Agent): 사람이 정하기 전에 다음 라운드의 콜드 리뷰를 부르면 막는다. 필요: python3 · git · gh
#
# **왜.** 「다음 라운드는 사람이 정한다」(`open-pr` 3.6)를 지키던 것은 3.6 의 5 셈 하나였다. 세션이 실행해 출력을 읽는
# 명령이라 건너뛰면 막는 것이 없었고, 한 프로젝트에서 라운드가 사람 승인 없이 스무 번 진행됐다(ADR-0006). 라운드는 콜드
# 리뷰가 있어야 올라가므로(`round_comment_cold.sh`), 그 리뷰를 부르는 순간을 막는다. ADR-0006 이 기각한 「같은 head 의
# 두 번째 라운드를 거부한다」와 달리 head 를 보지 않는다 — 라운드마다 head 가 바뀌어도 사람 계정 코멘트가 없으면 막는다.
#
# **무엇을 막나.** 메인 세션이 `cold-reviewer` 를 부를 때, 지금 브랜치의 열린 PR 에서 첫 줄이 `## 리뷰 ` 인 마지막
# 코멘트(라운드 코멘트) 뒤에 사람 계정 코멘트(`authorAssociation` 이 OWNER · MEMBER · COLLABORATOR)가 없으면 막는다.
# 라운드 코멘트를 사람 계정이 올렸으면 그 뒤의 코멘트를 세지 않는다. 기준은 3.6 의 5 와 같다. 다른 점은 앵커다 — 3.6 의
# 5 는 이번 head 의 라운드 코멘트를 앵커로 삼고, 이 훅은 마지막 라운드 코멘트를 삼는다. 리뷰를 부르는 순간에는 이번
# head 의 라운드 코멘트가 아직 없다.
#
# **무엇을 통과시키나.** `cold-reviewer` 가 아닌 에이전트 · git 레포 밖 · 브랜치가 없음(detached) · 봇 설정
# (`.claude/bot.json`)이 없음 · 열린 PR 이 없음 · 라운드 코멘트가 없음(1라운드). 봇 설정이 없으면 라운드 코멘트를 올릴 수
# 없고(`round_comment_cold.sh`), 사람 계정 코멘트도 글쓴이로 가리지 못한다.
#
# **판정 못 하면 막는다.** 훅 입력을 못 읽음 · gh 실패 · 시간 초과 · gh 가 낸 JSON 을 못 읽음.
#
# **무엇을 못 막나.** 사람 계정 코멘트의 내용은 보지 않는다 — 「멈춘다」를 골라도 통과한다. 다른 종류의 에이전트로
# 리뷰를 시키면 보지 않는다. 그 리뷰는 기록 훅이 기록하지 않아 라운드 코멘트로 올릴 수 없다(`round_comment_cold.sh`).
input=$(cat)
case "$input" in
  *cold-reviewer*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, re, subprocess, sys

TIMEOUT = 20
HUMAN = ('OWNER', 'MEMBER', 'COLLABORATOR')


def deny(why):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    deny("라운드 게이트가 훅 입력을 읽지 못해 콜드 리뷰를 막았다.")
if ((data.get('tool_input') or {}).get('subagent_type')) != 'cold-reviewer':
    sys.exit(0)
cwd = data.get('cwd') or os.getcwd()


def run(*args):
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        deny("라운드 게이트의 `%s` 가 %d초 안에 끝나지 않아 판정하지 못했다. 콜드 리뷰를 막았다 — 다시 부른다."
             % (' '.join(args[:3]), TIMEOUT))
    except OSError as e:
        deny("라운드 게이트가 `%s` 를 실행하지 못해 판정하지 못했다(%s). 콜드 리뷰를 막았다." % (args[0], e))


top = run('git', 'rev-parse', '--show-toplevel')
if top.returncode:
    sys.exit(0)
if not os.path.isfile(os.path.join(top.stdout.strip(), '.claude', 'bot.json')):
    sys.exit(0)
branch = run('git', 'branch', '--show-current').stdout.strip()
if not branch:
    sys.exit(0)


def gh(*args):
    r = run('gh', *args)
    if r.returncode:
        line = (r.stderr.strip().splitlines() or ['(오류 출력 없음)'])[0]
        deny("라운드 게이트의 `gh %s` 가 실패해 판정하지 못했다: %s. 콜드 리뷰를 막았다." % (' '.join(args[:2]), line))
    try:
        return json.loads(r.stdout)
    except ValueError:
        deny("라운드 게이트가 `gh %s` 의 출력을 JSON 으로 읽지 못해 판정하지 못했다. 콜드 리뷰를 막았다." % ' '.join(args[:2]))


prs = gh('pr', 'list', '--head', branch, '--state', 'open', '--json', 'number')
if not prs:
    sys.exit(0)
n = prs[0].get('number')
comments = (gh('pr', 'view', str(n), '--json', 'comments') or {}).get('comments') or []
last = None
for i, c in enumerate(comments):
    if re.match(r'\s*## 리뷰 ', c.get('body') or ''):
        last = i
if last is None:
    sys.exit(0)
if comments[last].get('authorAssociation') in HUMAN:
    after = 0
else:
    after = sum(1 for c in comments[last + 1:] if c.get('authorAssociation') in HUMAN)
if after:
    sys.exit(0)
deny("PR #%s 의 마지막 라운드 코멘트 뒤에 사람 계정 코멘트가 없다. 다음 라운드는 사람이 정한다(open-pr 3.6). "
     "3.5 의 창으로 결정을 받아 `bash .claude/hooks/human_comment.sh %s` 로 올린 뒤 콜드 리뷰를 부른다. 사람이 PR 웹에 "
     "결정을 썼으면 그 코멘트가 올라간 뒤에 부른다." % (n, n))
PY
