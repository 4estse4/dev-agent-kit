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
# ` · ` 로 잇는다 — 그 답은 조각을 `, ` 로 이은 글자이고 `, ` 나 `"` 가 든 조각은 JSON 문자열로 감싸 오므로, Claude
# Code 가 되돌려 읽는 규칙대로 나눈다. 보기에 없는 말(사람이 직접 쓴 말)이나 보기에 단 메모(`annotations` 의
# `notes`)가 있는 질문은 줄을 적지 않고 그 머리말을 `free` 에 표시한다 — 메모는 결정의 조건이라 보기만 올리면
# 빠진다. 답을 비운 질문도 `free` 이고, 창에 보기 대신 쓴 글(`response`)이 있으면 표지가 있는 질문을 모두
# `free` 로 적는다 — Claude Code 는 그 글만 모델에 주므로 세션은 그 글대로 움직인다. 그대로 올리지 않고 같은
# 머리말의 창으로 다시 받는다(`open-pr` 3.5). 사람이 자리를 비워 저절로 닫힌 창(`afkTimeoutMs`)과 질문을 더
# 요청하며 닫은 창(`followUp`)은 사람이 제출한 것이 아니라서 기록하지 않는다.
#
# **어디에.** 세션을 연 프로젝트(`CLAUDE_PROJECT_DIR`)의 `<git 공통 디렉터리>/kit-bot/windows/<PR>.jsonl` 에 기록
# 하나를 한 줄로 더한다. 훅 입력의 `cwd` 는 세션의 셸이 `cd` 한 자리를 따라가서, 그것으로 정하면 프로젝트 안의
# 다른 레포에 `cd` 해 있을 때 기록이 그 레포에 생긴다. git 공통 디렉터리는 절대 경로로 받는다. 세션은 봇
# 디렉터리를 읽지도 쓰지도 못한다 — 셸 명령은 가드 훅(`bot_guard.sh`)이, Read · Write · Edit 도구는 설치되는
# `settings.json` 의 deny 가 막는다. 봇 설정이 있는 레포 안에서 세션이 이 훅을 직접 실행해 지어낸 창 결과로
# 기록을 만드는 명령도 가드 훅이 막는다.
#
# 입력의 `tool_response` 는 세션 기록에 남는 창의 결과와 같은 모양이다: `questions` 와, 질문 글자에서 고른
# 보기로 가는 `answers`, 질문 글자에서 메모로 가는 `annotations`. 백그라운드 세션에서 이 이벤트의 실제 입력을
# 기록해 확인했다(2026-09-29). 여러 보기 답의 모양과 `response` · `afkTimeoutMs` · `followUp` 은 Claude Code
# 2.1.283 · 2.1.284 의 코드에서 읽었다.
#
# **올리는 명령의 안내.** 가드 훅과 설치되는 `settings.json` 의 allow 는 레포 루트에서 입력한
# `bash .claude/hooks/human_comment.sh <PR>` 만 받고, 게시 스크립트는 셸이 있는 레포에서 기록을 읽는다. 그래서
# 세션의 셸(`cwd`)이 프로젝트의 레포 루트가 아니면 먼저 그 루트로 옮기라고 적는다. 셸이 세션 도중 들어간
# worktree 에 있으면(아래 「올릴 자리」) 옮기라고 하지 않고, 그 worktree 루트에서 이 훅의 스크립트까지의 경로를
# 적는다. 그 명령은 allow 와 모양이 달라 권한 검사를 거치고(default 모드는 권한 프롬프트, auto 모드는 분류기),
# 안내에 그것을 적는다.
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
# 봇 설정 · 레포 루트 · 기록 자리는 셸이 있는 자리(cwd)가 아니라 세션을 연 프로젝트에서 구한다
proj = os.environ.get('CLAUDE_PROJECT_DIR') or None
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=proj, capture_output=True, text=True)
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

def split(ans):
    """여러 보기 답을 조각으로 나눈다. 답은 조각을 `, ` 로 이은 글자이고, `, ` 나 `"` 가 든 조각은 JSON 문자열로
    감싸 온다 — Claude Code 가 답을 이을 때와 되돌려 읽을 때의 규칙 그대로다. 모양이 틀리면 None 이다."""
    out, s = [], ans
    while True:
        if s.startswith('"'):
            try:
                val, end = json.JSONDecoder().raw_decode(s)
            except ValueError:
                return None
            if not isinstance(val, str):
                return None
            out.append(val)
            s = s[end:]
        else:
            i = s.find(', ')
            piece = s if i < 0 else s[:i]
            if '"' in piece:
                return None
            out.append(piece)
            s = '' if i < 0 else s[i:]
        if not s:
            return out
        if not s.startswith(', '):
            return None
        s = s[2:]


marked = [(q, MARK.search(q.get('question') or '')) for q in qs]
marked = [(q, m.group(1)) for q, m in marked if m]
if not marked:
    sys.exit(0)

# 사람이 자리를 비워 저절로 닫힌 창과 질문을 더 요청하며 닫은 창은 사람이 제출한 것이 아니다 — 게시 동의가 아니다
if resp.get('afkTimeoutMs') or resp.get('followUp'):
    why = '사람이 자리를 비워 창이 저절로 닫혔다' if resp.get('afkTimeoutMs') else '사람이 질문을 더 요청하며 창을 닫았다'
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext":
        "PR #%s: %s. 사람 계정으로 올릴 결정은 기록하지 않았다 — 같은 머리말의 창을 다시 띄워 받는다(open-pr 3.5)."
        % (', #'.join(sorted({pr for _, pr in marked})), why)}}, ensure_ascii=False))
    sys.exit(0)

notes_of = resp.get('annotations') if isinstance(resp.get('annotations'), dict) else {}
# 창에 보기 대신 쓴 글(`response`)이 있으면 Claude Code 는 모델에 그 글만 준다. 세션은 그 글대로 움직이므로, 고른
# 보기가 있어도 표지가 있는 질문은 모두 정하지 않은 것으로 적는다
typed = isinstance(resp.get('response'), str) and resp['response'].strip()
got = {}
for q, pr in marked:
    rec = got.setdefault(pr, {'lines': [], 'free': [], 'why': []})
    header = q.get('header') or ''
    labels = [o.get('label') for o in q.get('options') or [] if isinstance(o.get('label'), str) and o.get('label')]
    ans = answers.get(q.get('question'))
    picked = (split(ans) if isinstance(ans, str) else None) if q.get('multiSelect') else [ans]
    note = notes_of.get(q.get('question'))
    # 보기에 단 메모는 결정의 일부다 — 보기만 올리면 사람이 붙인 조건이 빠진다
    noted = isinstance(note, dict) and isinstance(note.get('notes'), str) and note['notes'].strip()
    if picked and all(p in labels for p in picked) and not noted and not typed:
        rec['lines'].append('- %s: %s' % (header, ' · '.join(SUGGEST.sub('', p) for p in picked)))
        continue
    rec['free'].append(header)
    if typed:
        rec['why'].append('「%s」 — 창에 쓴 글이 있다' % header)
    elif not noted and (ans is None or (isinstance(ans, str) and not ans.strip())):
        rec['why'].append('「%s」 — 답이 없다' % header)
    else:
        rec['why'].append('「%s」 — 직접 쓴 말이나 메모가 있다' % header)

# 절대 경로로 받는다 — 상대 경로는 git 을 실행한 자리 기준이라 루트에 붙이면 레포 밖을 가리킬 수 있다
common = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=proj,
                        capture_output=True, text=True)
if common.returncode or not common.stdout.strip():
    sys.exit(0)
where = os.path.join(common.stdout.strip(), 'kit-bot', 'windows')
os.umask(0o077)
os.makedirs(where, exist_ok=True)
at = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
# 올릴 자리는 프로젝트의 레포 루트다. 다만 셸이 세션 도중 들어간 worktree 에 있으면 그 worktree 의 루트다.
# 게시 스크립트는 셸이 있는 레포에서 기록을 읽는데 worktree 는 같은 기록을 보고, 옮기라고 하면 셸이 worktree
# 밖으로 나가 그 뒤의 명령이 다른 체크아웃에서 실행되거나 Claude Code 가 cwd 를 되돌려 같은 안내가 되풀이된다.
# 그런 worktree 는 git 공통 디렉터리가 프로젝트와 같고, 루트가 Claude Code 가 worktree 를 만드는 두 자리 가운데
# 하나에 있다 — 프로젝트 루트 안, 또는 원래 체크아웃(공통 디렉터리의 상위)의 `.claude` 아래 `worktrees`. 세션을
# linked worktree 에서 열면 Claude Code 는 뒤쪽에 만든다. 그 밖의 같은 레포 체크아웃은 worktree 로 보지 않는다
post = os.path.realpath(root)
pcommon = os.path.realpath(common.stdout.strip())
ctop = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd, capture_output=True, text=True)
ccommon = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=cwd,
                         capture_output=True, text=True)
cpath = os.path.realpath(ctop.stdout.strip())
# 프로젝트 루트 자체는 worktree 가 아니다 — `claude -w` 로 연 세션은 프로젝트 루트가 원래 체크아웃의 그 자리에 있다
worktree = (ctop.returncode == 0 and ccommon.returncode == 0
            and os.path.realpath(ccommon.stdout.strip()) == pcommon and cpath != post
            and (cpath.startswith(post + os.sep)
                 or cpath.startswith(os.path.join(os.path.dirname(pcommon), '.claude', 'worktrees') + os.sep)))
if worktree:
    post = cpath
# 둘 다 실제 경로로 바꿔 견준다 — 훅의 자리는 논리 경로이고 git 이 낸 루트는 실제 경로라, 레포 경로에 심링크가
# 있으면 그대로 견준 상대 경로가 레포 밖을 돌아온다
script = os.path.relpath(os.path.realpath(os.path.join(here, 'human_comment.sh')), post)
# 가드 훅은 게시 명령의 경로를 cwd 기준으로 푼다
move = '' if os.path.realpath(cwd or os.getcwd()) == post else '먼저 `cd %s` 로 옮긴 뒤(한 줄로 잇지 않는다) ' % post
# worktree 의 `.claude/hooks/` 는 이 훅이 실행되는 디렉터리가 아니라 가드 훅이 받지 않으므로 이 훅의 스크립트까지
# 경로로 부른다. 그 명령은 설치되는 settings.json 의 allow 와 모양이 달라 권한 검사를 거친다 — default 모드에서는
# 권한 프롬프트가 표시되고 auto 모드에서는 분류기가 정한다
prompt = (' 이 명령은 설치되는 settings.json 의 allow(`bash .claude/hooks/human_comment.sh <PR>`)와 모양이 달라 '
          '권한 검사를 거친다 — default 모드에서는 권한 프롬프트가 한 번 표시되고 auto 모드에서는 분류기가 정한다. '
          '셸이 있는 worktree 의 `.claude/hooks/` 는 이 훅이 실행되는 디렉터리가 아니라 가드 훅이 받지 않는다.'
          ) if worktree else ''
notes = []
for pr, rec in got.items():
    with open(os.path.join(where, pr + '.jsonl'), 'a', encoding='utf-8') as fh:
        fh.write(json.dumps({'at': at, 'session': data.get('session_id'), 'lines': rec['lines'],
                             'free': rec['free']}, ensure_ascii=False) + '\n')
    if rec['free']:
        notes.append("PR #%s: 보기로 정하지 않은 질문(%s)이 있어 그대로 올리지 않는다. 같은 머리말의 창을 다시 띄워 "
                     "받는다 — 직접 쓴 말 · 메모 · 창에 쓴 글이 있는 질문은 결정이 담긴 이어진 한 구간이나 요지를 "
                     "보기로 만들고, 답이 없는 질문은 같은 보기로 다시 묻는다(open-pr 3.5)."
                     % (pr, ', '.join(rec['why'])))
    else:
        notes.append("PR #%s: 사람 계정으로 올릴 결정 %d줄을 기록했다. 이번 head 의 라운드 코멘트가 이미 올라가 있으면 "
                     "지금 %s`bash %s %s` 로 올리고, 라운드 도중에 정한 것이면 라운드 코멘트를 올린 뒤 `%s` 에서 "
                     "같은 명령으로 올린다(open-pr 3.1 · 3.5).%s"
                     % (pr, len(rec['lines']), move, script, pr, post, prompt))
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                         "additionalContext": " ".join(notes)}}, ensure_ascii=False))
PY
