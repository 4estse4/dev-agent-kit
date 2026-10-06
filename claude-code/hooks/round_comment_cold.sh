#!/usr/bin/env bash
# PreToolUse(Bash): 라운드 코멘트의 콜드 리뷰 전문이 기록 훅이 남긴 같은 head 의 보고와 글자로 같은지 본다.
# 다르거나 기록이 없으면 그 `gh pr comment` 를 막는다. 필요: python3 · git
#
# **왜.** 라운드 코멘트는 사람의 승인 없이 올라간다(`open-pr` 3.4). 콜드 리뷰 전문은 세션이 옮겨 적었으므로
# 옮기다 바뀌어도, 리뷰를 실행하지 않고 지어내도 확인할 것이 없었다. 기록 훅
# (`review_record.sh`)이 에이전트가 돌려준 글을 봇 디렉터리에 남기고, 이 훅이 라운드 코멘트의 전문을 그 기록과
# 대조한다. 세션은 `cold_review.sh <head>` 의 출력을 그대로 넣는다.
#
# **라운드 코멘트(첫 줄 `## 리뷰 `)에서 무엇을 막나.**
# - 세션을 연 프로젝트에 봇 설정(`.claude/bot.json`)이 없을 때 — 대조할 기록이 없다. 봇 설정이 없으면
#   세션이 bash 로 봇 디렉터리에 쓸 수 있어 기록 훅이 기록하지 않는다. 킷은 봇과 함께 쓴다
# - 접히지 않은 부분에 `리뷰한 head: <40자>` 줄이 없을 때
# - `<summary>콜드 리뷰 전문</summary>` 블록이 없을 때
# - 그 head 의 기록이 없을 때 — 콜드 리뷰가 그 head 를 리뷰해 보고를 돌려준 적이 없다
# - 블록 안의 글이 그 head 의 어느 기록과도 글자로 같지 않을 때. 앞뒤 빈 줄만 무시한다
#
# **어떤 게시 명령을 보나.** 인용 훅(`round_comment_quotes.sh`)과 같은 해석(`round_comment_cmd.py`)으로 읽어
# 정규형이면 본다 — `-F` · `--body-file=` · 번호를 뒤에 둔 모양 · `--edit-last` 도 정규형이다. 정규형이 아니면
# 인용 훅이 같은 해석으로 막는다.
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 입력한 게시만 본다. 사람이 손으로 올리거나 웹으로 올리면 훅이 불리지
# 않는다. 기록은 에이전트가 실제로 돌려준 글이라는 것까지 보장한다 — 그 에이전트가 무엇을 리뷰했는지는 보장하지
# 않는다.
#
# **판정 못 하면 막는다.** 본문 파일을 못 읽으면 `round_comment_quotes.sh` 가 막으므로 여기서는 건너뛴다.
#
# **제목 앵커는 스킬과 같은 글자다.** 라운드 코멘트는 첫 줄 `## 리뷰 ` 로, 콜드 전문은
# `<summary>콜드 리뷰 전문</summary>` 로 고른다. 그 글자를 바꾸면 이 파일도 같이 바꾼다.
input=$(cat)
case "$input" in
  *comment*) ;;
  *) exit 0 ;;
esac

# 공유 파일(round_comment_cmd.py)을 읽어도 훅 디렉터리에 __pycache__ 를 남기지 않는다.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, re, subprocess, sys

# 명령을 읽는 규칙은 인용 훅(round_comment_quotes.sh)과 같이 쓰는 round_comment_cmd.py 에 있다.
sys.path.insert(0, os.environ['HOOK_DIR'])
import round_comment_cmd  # noqa: E402

ROUND = re.compile(r'^\s*## 리뷰 ')
HEAD = re.compile(r'^리뷰한 head:\s*([0-9a-f]{40})\s*$')
SUMMARY = re.compile(r'^\s*<summary>콜드 리뷰 전문</summary>\s*$')
CLOSE = re.compile(r'^</details>\s*$')


def deny(why):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
# 정규형이 아니면(deny) 인용 훅이 같은 해석으로 막으므로 여기서는 건너뛴다.
kind, got = round_comment_cmd.parse((data.get('tool_input') or {}).get('command') or '')
if kind != 'ok':
    sys.exit(0)
path = got['path']
try:
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
except (OSError, UnicodeDecodeError):
    sys.exit(0)
if not ROUND.match(body):
    sys.exit(0)

# 기록 훅(review_record.sh)과 같이 세션을 연 프로젝트에서 기록을 찾는다. 훅 입력의 cwd 는 세션이 cd 한 자리를
# 따라가서, 프로젝트 안의 다른 레포에 cd 해 있으면 그 레포의 봇 디렉터리를 봤다.
proj = os.environ.get('CLAUDE_PROJECT_DIR') or None
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=proj, capture_output=True, text=True)
if top.returncode or not os.path.isfile(os.path.join(top.stdout.strip(), '.claude', 'bot.json')):
    deny("세션을 연 프로젝트에는 봇 설정(.claude/bot.json)이 없어, 라운드 코멘트의 콜드 리뷰 전문을 대조할 기록이 없다. "
         "봇 설정이 없으면 세션이 봇 디렉터리에 쓸 수 있어 기록 훅이 기록하지 않는다. 킷은 봇과 함께 쓴다 — "
         "켜는 법은 docs/process/kit-guide.md 의 「봇 계정과 사람의 승인」 절에 있다.")

lines = body.split('\n')
head, depth = None, 0
for line in lines:
    if re.match(r'^\s*<details>', line):
        depth += 1
    elif depth and re.match(r'^\s*</details>', line):
        depth -= 1
    elif not depth and HEAD.match(line):
        head = HEAD.match(line).group(1)
        break
if not head:
    deny("라운드 코멘트의 접히지 않은 부분에 `리뷰한 head: <40자>` 줄이 없다. 콜드 리뷰 기록을 그 head 로 찾는다.")

start = next((i for i, line in enumerate(lines) if SUMMARY.match(line)), None)
end = None
if start is not None:
    end = max((i for i in range(start + 1, len(lines)) if CLOSE.match(lines[i])), default=None)
if start is None or end is None:
    deny("라운드 코멘트에 콜드 리뷰 전문 블록(<summary>콜드 리뷰 전문</summary> … </details>)이 없다. "
         "`bash .claude/hooks/cold_review.sh %s` 의 출력을 그 블록에 그대로 넣는다." % head)
cold = '\n'.join(lines[start + 1:end]).strip('\n')

common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=proj,
                        capture_output=True, text=True)
reports = []
try:
    with open(os.path.join(common.stdout.strip(), 'kit-bot', 'reviews', head + '.jsonl'), encoding='utf-8') as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r.get('report'), str):
                reports.append(r['report'].strip('\n'))
except OSError:
    pass
if not reports:
    deny("head %s 의 콜드 리뷰 기록이 없다. 콜드 리뷰 에이전트가 이 head 를 리뷰해 보고를 돌려준 뒤에 올린다 — "
         "라운드 도중에 head 가 바뀌었으면 그 라운드는 무효다(open-pr 3.3)." % head)
if cold not in reports:
    deny("라운드 코멘트의 콜드 리뷰 전문이 기록과 다르다. 옮겨 적지 말고 `bash .claude/hooks/cold_review.sh %s` 의 "
         "출력을 그대로 넣는다." % head)
sys.exit(0)
PY
exit 0
