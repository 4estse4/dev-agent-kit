#!/usr/bin/env bash
# PreToolUse · PostToolUse(SubagentHandback) · SubagentStop: 콜드 리뷰 보고를 봇 디렉터리에 기록한다.
# 필요: python3 · git
#
# **왜.** 콜드 리뷰는 에이전트가 보고를 돌려주고 세션이 그 글을 라운드 코멘트로 옮겨 적었다. 옮기면서 글이
# 바뀌어도, 리뷰를 실행하지 않고 글을 지어내도 그 코멘트의 글 말고는 확인할 것이 없었다. 이 훅이 에이전트가
# 돌려준 글을 세션의 손을 거치지 않고 기록하고, 라운드 코멘트 게시 훅(`round_comment_cold.sh`)이 그 기록과
# 대조한다. 세션은 기록을 `cold_review.sh <head>` 로 꺼내 쓴다.
#
# **무엇을 기록하나.** 봇 설정(`.claude/bot.json`)이 있고, 에이전트 종류(`agent_type`)가 `cold-reviewer` 인
# 에이전트의 보고만이다. 다른 에이전트가 콜드 리뷰 모양의 글을 돌려줘도 기록하지 않으므로, 리뷰를 다른 에이전트가
# 대신하면 라운드 코멘트 게시 훅이 기록을 못 찾아 막는다. 보고는 두 자리 가운데 하나로 온다(Claude Code 2.1.286 의
# 헤드리스 세션으로 확인했다):
#   · 기본 모드 — `SubagentStop` 의 `last_assistant_message`
#   · auto 모드 — 에이전트가 `SubagentHandback` 으로 보고한다. 보고는 그 도구의 `tool_input.message` 다.
#     그 뒤의 `SubagentStop` 의 `last_assistant_message` 는 보고가 아니라 에이전트의 맺음말이다(문서: "the
#     subagent's closing text, if any, which is not the delivered report"). 맺음말은 흔하다
# 그래서 `PostToolUse(SubagentHandback)` 와 `SubagentStop` 둘에서 기록하되, 이미 기록한 실행(`agent_id`)의
# `SubagentStop` 은 맺음말이라 보지 않는다.
#
# **어디에.** `<git 공통 디렉터리>/kit-bot/reviews/<리뷰한 head>.jsonl` 에 실행마다 한 줄 — agent_id · agent_type ·
# head · 시각 · 받은 이벤트 · 보고 전문. head 는 보고의 `리뷰한 head:` 줄에서 읽고, 40자가 아니면 `unknown` 이다.
# 세션은 봇 디렉터리를 읽지도 쓰지도 못하고(설치되는 settings 의 deny · `bot_guard.sh`), 이 훅을 직접
# 실행하는 명령도 `bot_guard.sh` 가 막는다. 그래서 기록은 에이전트가 실제로 돌려준 글이다.
#
# **마지막 줄이 `**Verdict**:` 가 아니면 한 번 막는다.** 그 줄이 리뷰의 판정이고(`cold-reviewer` 정의는 반드시
# 마지막 줄이라고 한다) 라운드 코멘트의 머리가 그 줄을 쓴다. 가운데 줄은 보지 않는다 — 재리뷰 보고는 앞 라운드의
# Verdict 줄을 옮겨 적기도 한다.
# auto 모드는 `PreToolUse(SubagentHandback)` 에서 보고를 거부하고, 기본 모드는 `SubagentStop` 에서 block 해
# 에이전트가 다시 끝내게 한다. 같은 실행에서 두 번째부터는 막지 않고 기록한다 — 되풀이를 막는다.
#
# **봇 설정이 없으면 아무것도 하지 않는다.** 그때는 bot_guard.sh 가 실행되지 않아 세션이 bash 로 봇 디렉터리에
# 쓸 수 있으므로, 기록이 에이전트의 글이라는 보장이 없다. 라운드 코멘트 게시 훅은 그때 콜드 전문이 든 라운드
# 코멘트를 막는다. 킷은 봇과 함께 쓴다.
input=$(cat)
case "$input" in
  *cold-reviewer*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" python3 - <<'PY'
import datetime, json, os, re, subprocess, sys

try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
ev = data.get('hook_event_name')
if data.get('agent_type') != 'cold-reviewer':
    sys.exit(0)
if ev in ('PreToolUse', 'PostToolUse'):
    if data.get('tool_name') != 'SubagentHandback':
        sys.exit(0)
    report = (data.get('tool_input') or {}).get('message')
elif ev == 'SubagentStop':
    report = data.get('last_assistant_message')
else:
    sys.exit(0)
if not isinstance(report, str) or not report.strip():
    sys.exit(0)

cwd = data.get('cwd') or None
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd, capture_output=True, text=True)
if top.returncode or not os.path.isfile(os.path.join(top.stdout.strip(), '.claude', 'bot.json')):
    sys.exit(0)
common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=cwd,
                        capture_output=True, text=True)
if common.returncode:
    sys.exit(0)
d = os.path.join(common.stdout.strip(), 'kit-bot', 'reviews')
os.makedirs(d, exist_ok=True)
agent = str(data.get('agent_id') or '')
tag = re.sub(r'[^0-9A-Za-z_-]', '_', agent or 'none')
recorded = os.path.join(d, '.recorded-' + tag)
if ev == 'SubagentStop' and os.path.exists(recorded):
    sys.exit(0)                 # 이미 SubagentHandback 으로 받은 실행이다. 이 글은 맺음말이다

last = next((l for l in reversed(report.splitlines()) if l.strip()), '')
if not last.startswith('**Verdict**:'):
    mark = os.path.join(d, '.no-verdict-' + tag)
    if not os.path.exists(mark) and not (ev == 'SubagentStop' and data.get('stop_hook_active')):
        open(mark, 'w').close()
        why = ("콜드 리뷰 보고의 마지막 줄은 `**Verdict**: Request changes | Comment | Approve — <한 문장>` 이다. "
               "이 보고의 마지막 줄은 그렇지 않다. 그 줄을 붙여 보고 전문을 다시 돌려준다 — 직전 라운드 코멘트를 "
               "못 찾아 정의대로 리뷰하지 않고 멈춘 보고면 그 까닭을 그 줄의 한 문장에 적는다.")
        if ev == 'PreToolUse':
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                     "permissionDecision": "deny",
                                                     "permissionDecisionReason": why}}, ensure_ascii=False))
            sys.exit(0)
        if ev == 'SubagentStop':
            print(json.dumps({"decision": "block", "reason": why}, ensure_ascii=False))
            sys.exit(0)
if ev == 'PreToolUse':
    sys.exit(0)

m = re.search(r'^리뷰한 head:\s*([0-9a-f]{40})\s*$', report, re.M)
head = m.group(1) if m else 'unknown'
path = os.path.join(d, head + '.jsonl')
try:
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get('agent_id') == agent and r.get('report') == report:
                sys.exit(0)
except OSError:
    pass
row = {'agent_id': agent, 'agent_type': data.get('agent_type') or '', 'head': head,
       'time': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
       'event': ev, 'report': report}
with open(path, 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(row, ensure_ascii=False) + '\n')
# 맺음말은 SubagentHandback 으로 보고한 실행에만 생긴다. 기본 모드의 실행에 표시를 남기면, 그 실행을 이어
# 실행(같은 agent_id)한 뒤의 보고를 맺음말로 보고 기록하지 않는다.
if ev == 'PostToolUse':
    open(recorded, 'w').close()
PY
exit 0
