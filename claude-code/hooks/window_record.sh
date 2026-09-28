#!/usr/bin/env bash
# PostToolUse(AskUserQuestion): 사람 계정으로 올릴 결정 창에서 사람이 고른 보기를 봇 디렉터리에 기록한다.
# 필요: python3 · git
#
# **왜.** 사람 계정 코멘트는 사람의 결정이 사람의 글로 남는 자리다. 세션이 그 글을 쓰면 사람이 고르지 않은
# 말이 사람의 결정으로 남을 수 있고, 응답에 전문을 보이고 허락받는 규칙만으로는 지켜지지 않았다. 그래서 글은
# 사람이 고른 보기로만 만든다. 이 훅이 그 줄을 만들고, `human_comment.sh <PR>` 이 이 기록만 올린다.
#
# **무엇을 기록하나.** 봇 설정(`.claude/bot.json`)이 있고, 질문에 「이 결정은 사람 계정으로 PR #N 에 그대로
# 올라간다」가 적힌 질문만이다. 그 글자가 사람에게 게시를 알리므로, 고른 것이 곧 게시 동의다. 질문마다
# `- <머리말>: <고른 보기>` 한 줄이고, 한 창의 여러 질문은 차례대로 한 기록에 담는다. 보기에 세션이 붙인 추천
# 표시(`(추천)` · `(Recommended)`)는 뗀다 — 사람이 한 말이 아니다. 여러 보기를 고를 수 있는 질문은 고른 보기를
# ` · ` 로 잇는다 — 그 답은 보기 이름을 `, ` 로 이은 글자이고 이름 안에도 `, ` 가 있을 수 있어, 이름 그대로 맞춰
# 나눈다. 보기에 없는 말(사람이 직접 쓴 말)은 적지 않고 그 머리말을 `free` 에 표시한다 — 그대로 올리지 않고
# 결정이 담긴 구간을 보기로 만든 창으로 다시 받는다(`open-pr` 3.5).
#
# **어디에.** `<git 공통 디렉터리>/ai-kit-bot/windows/<PR>.jsonl` 에 기록 하나를 한 줄로 더한다. 세션은 봇
# 디렉터리를 읽지도 쓰지도 못한다 — 셸 명령은 막기 훅(`bot_guard.sh`)이, Read · Write · Edit 도구는 설치되는
# `settings.json` 의 deny 가 막는다.
#
# 입력의 `tool_response` 는 세션 기록에 남는 창의 결과와 같은 모양이다: `questions` 와, 질문 글자에서 고른
# 보기로 가는 `answers`. 백그라운드 세션에서 이 이벤트의 실제 입력을 기록해 확인했다(2026-09-29).
input=$(cat)
case "$input" in
  *AskUserQuestion*) ;;
  *) exit 0 ;;
esac
HOOK_INPUT="$input" exec python3 - "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import datetime, json, os, re, subprocess, sys

here = sys.argv[1]
try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'AskUserQuestion':
    sys.exit(0)
cwd = data.get('cwd') or None
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd, capture_output=True, text=True)
root = top.stdout.strip()
if top.returncode or not os.path.isfile(os.path.join(root, '.claude', 'bot.json')):
    sys.exit(0)

MARK = re.compile(r'이 결정은 사람 계정으로 PR #(\d+) 에 그대로 올라간다')
SUGGEST = re.compile(r'\s*\((?:추천|Recommended)\)\s*$')
resp = data.get('tool_response') or {}
answers = resp.get('answers') if isinstance(resp, dict) else None
if not isinstance(answers, dict):
    sys.exit(0)
qs = (data.get('tool_input') or {}).get('questions') or resp.get('questions') or []

def split(ans, labels):
    """여러 보기 답을 보기 이름으로 나눈다. 답은 보기 이름을 `, ` 로 이은 글자이고 이름 안에도 `, ` 가 있을 수
    있어, 앞에서부터 이름 그대로 맞춰 본다. 보기에 없는 말이 남으면 None 이다."""
    picked = []
    while ans:
        hit = max((l for l in labels if ans == l or ans.startswith(l + ', ')), key=len, default=None)
        if hit is None:
            return None
        picked.append(hit)
        ans = ans[len(hit) + 2:]
    return picked


got = {}
for q in qs:
    m = MARK.search(q.get('question') or '')
    if not m:
        continue
    rec = got.setdefault(m.group(1), {'lines': [], 'free': []})
    header = q.get('header') or ''
    labels = [o.get('label') for o in q.get('options') or [] if isinstance(o.get('label'), str) and o.get('label')]
    ans = answers.get(q.get('question'))
    picked = (split(ans, labels) if isinstance(ans, str) else None) if q.get('multiSelect') else [ans]
    if picked and all(p in labels for p in picked):
        rec['lines'].append('- %s: %s' % (header, ' · '.join(SUGGEST.sub('', p) for p in picked)))
    else:
        rec['free'].append(header)
if not got:
    sys.exit(0)

common = subprocess.run(['git', 'rev-parse', '--git-common-dir'], cwd=cwd, capture_output=True, text=True)
where = os.path.join(os.path.abspath(os.path.join(root, common.stdout.strip())), 'ai-kit-bot', 'windows')
os.umask(0o077)
os.makedirs(where, exist_ok=True)
at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
script = os.path.relpath(os.path.join(here, 'human_comment.sh'), root)
notes = []
for pr, rec in got.items():
    with open(os.path.join(where, pr + '.jsonl'), 'a', encoding='utf-8') as fh:
        fh.write(json.dumps({'at': at, 'session': data.get('session_id'), 'lines': rec['lines'],
                             'free': rec['free']}, ensure_ascii=False) + '\n')
    if rec['free']:
        notes.append("PR #%s: 사람이 보기 대신 직접 쓴 말(%s)이 있어 그대로 올리지 않는다. 결정이 담긴 이어진 한 구간을 "
                     "글자 그대로 보기로 만든 창을 같은 머리말로 다시 띄워 받는다(open-pr 3.5)." % (pr, ', '.join(rec['free'])))
    else:
        notes.append("PR #%s: 사람 계정으로 올릴 결정 %d줄을 기록했다. 지금 `bash %s %s` 로 올린다(open-pr 3.5)."
                     % (pr, len(rec['lines']), script, pr))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                         "additionalContext": " ".join(notes)}}, ensure_ascii=False))
PY
