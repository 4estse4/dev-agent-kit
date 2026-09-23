#!/usr/bin/env bash
# PreToolUse(Bash): 라운드 코멘트의 `(사람)` 인용이 그 PR 의 3.5 코멘트에 글자 그대로 있는지 본다.
# 없으면 그 `gh pr comment` 를 막는다. 3.5 코멘트에는 사람에게 묻게 한다. 필요: python3 · gh
#
# **왜 훅인가.** 라운드 코멘트는 사람의 승인 없이 올라간다(`open-pr` 3.4). 그 코멘트에서
# 다음 라운드의 두 리뷰가 다시 판정하지 않는 것은 `(사람)` 인용 하나다. 그 대조를 스킬 안에
# 두면 모델이 안 따를 때 사라지므로 모델 밖인 여기 둔다. 근거는
# `docs/process/verification-stages.md` 의 「사람의 승인이 필요한 행동」.
#
# **본문을 넘기는 `gh pr comment` 는 한 줄 정규형만 받는다.**
#
#     gh pr comment <N> [-R <레포>] --body-file <절대 경로>
#
# `\` 줄넘김만 공백으로 잇는다. 다른 명령 · 줄바꿈 · 주석 · 리다이렉트 · 래퍼(`bash -c`)와
# 이은 것은 해석하지 않고 막는다. 셸 문자열을 해석하는 폭을 넓힐 때마다 새 우회가 났기
# 때문이다(같은 명령 안에서 본문 파일을 바꾼 뒤 게시하는 것도 이것으로 닫힌다). 경로는
# 절대 경로만 받는다 — 명령 안의 `cd` 를 이 훅이 못 따라간다. 본문 없는 호출(`--help` ·
# `--delete-last`)과 heredoc 안의 글(커밋 메시지 · 초안)은 게시가 아니라서 건너뛴다.
#
# **라운드 코멘트(첫 줄 `## 리뷰 `)에서 무엇을 막나.** 접힌 블록(`<details>`)을 뺀 부분에서
# - `(사람…) "…"` 의 따옴표 조각이 3.5 코멘트의 `(사람)` 인용 어디에도 없을 때. `…` 로 줄인
#   조각들은 한 인용 안에 순서대로 있어야 한다
# - 백틱 밖의 `(사람…)` 바로 뒤에 따옴표 인용이 없거나, 따옴표가 닫히지 않을 때.
#   대조할 것이 없어 이 훅을 비켜 간다. 백틱 안은 예시라서 안 본다
#
# **3.5 코멘트(`### N라운드에 사람이 준 답`)에는 `"ask"` 를 낸다.** 그 코멘트가 대조의
# 원본이라, 세션이 승인 없이 올리면 원본을 스스로 만드는 셈이다. `ask` 규칙이 없는
# 레포에서도 사람이 한 번 누르게 한다.
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 칠 때만 걸린다. 사람이 손으로 올리거나, 다른
# 명령(`gh api` · `gh issue comment <PR 번호>`)이나 heredoc 으로 넘긴 스크립트(`bash <<EOF`)나
# 웹으로 올리면 안 걸린다. 대조의 원본인 3.5 코멘트의 인용이 진짜 사람 말인지는 이 훅이
# 모른다. 3.5 코멘트는 사람이 승인하고 올린다.
#
# **통과시킬 때 아무것도 내지 않는다.** 훅의 `"allow"` 는 권한 프롬프트를 건너뛰게 하지만
# `ask` 규칙은 그대로 평가된다(공식 문서: "Deny and ask rules … are still evaluated regardless
# of what the hook returns"). 설치된 레포의 `ask` 에 있는 `gh pr comment` 프롬프트는 그대로 뜬다.
#
# **판정 못 하면 막는다.** 본문 파일을 못 읽거나(없음 · UTF-8 아님) `gh` 가 실패하거나 없으면
# 라운드 코멘트인지 인용이 맞는지 모른다. 판정 못 한 것을 통과로 치지 않는다.
# **이 스크립트가 못 돌면 막지 못한다.** `python3` 가 없거나, 시간을 넘기거나, 파일이 없으면
# 훅이 오류로 끝나고 문서대로 호출은 그대로 진행된다. `ask` 에 `gh pr comment` 가 없는
# 레포에서는 그 라운드 코멘트가 대조 없이 나간다. 판정 못 해 막는 위의 경우와 다르다.
#
# **제목 앵커는 스킬과 같은 글자다.** 라운드 코멘트는 첫 줄 `## 리뷰 `, 3.5 코멘트는 제목
# `### N라운드에 사람이 준 답` 으로 고른다. 제목을 바꾸면 이 파일도 같이 바꾼다 — 그 제목을
# 쓰는 스킬들과 같은 `git grep` 에 걸린다.
input=$(cat)

# 모든 Bash 호출에 돌므로, `comment` 가 없는 호출은 파이썬을 띄우지 않고 나간다.
case "$input" in
  *comment*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" python3 - <<'PY'
import json, os, re, shlex, subprocess, sys

ROUND = re.compile(r'^\s*## 리뷰 ')
ANSWER = re.compile(r'^\s*### .*라운드에 사람이 준 답')
BULLET = re.compile(r'^\s*(?:[-*]|\d+\.)\s')
# 출처 라벨은 `(사람)` 과 `(사람, N라운드부터)` 둘뿐이다.
# `(사람이 연다)` 같은 괄호 글은 라벨이 아니다.
LABEL = re.compile(r'\(사람(?:\s*,[^)]*)?\)')
AFTER = re.compile(r'(?:\*\*)?\s*"')          # 라벨 바로 뒤. `**(사람)** "…"` 도 인용이다
BODY_FLAGS = ('-F', '--body-file', '-b', '--body', '-e', '--editor', '-w', '--web')
QMASK, LMASK = '＂', '(사​람'       # 백틱 안의 `"` 와 `(사람` 을 가린다
CANON = "`gh pr comment <N> [-R <레포>] --body-file <절대 경로>`"


def out(decision, why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


def deny(why):
    out("deny", why)


def mask(s):
    return re.sub(r'`[^`\n]*`',
                  lambda m: m.group(0).replace('"', QMASK).replace('(사람', LMASK), s)


def norm(s):
    return ' '.join(s.replace('**', '').split())


def show(s):
    return s.replace(QMASK, '"').replace(LMASK, '(사람')


def unfolded(body):
    """접힌 블록(`<details>` … `</details>`)을 뺀 줄들."""
    keep, depth = [], 0
    for line in body.split('\n'):
        if re.match(r'^\s*<details>', line):
            depth += 1
            continue
        if depth and re.match(r'^\s*</details>', line):
            depth -= 1
            continue
        if not depth:
            keep.append(line)
    return keep


def items(body):
    """불릿은 (불릿, 이어 붙인 글), 불릿 밖의 줄은 (None, 줄) 로 돌려준다. 백틱 안은 가린다.

    불릿은 다음 불릿 · `→` 줄 · 빈 줄 · 들여쓰지 않은 줄에서 끝난다.
    `→` 뒤는 세션의 판단이라 인용이 아니다.
    """
    got, cur = [], None
    for line in unfolded(body):
        is_bullet = BULLET.match(line)
        ends = is_bullet or re.match(r'^\s*→', line) or not line.strip() \
            or not re.match(r'^\s', line)
        if ends and cur is not None:
            got.append(('b', mask(cur)))
            cur = None
        if is_bullet:
            cur = line
        elif cur is not None and not ends:
            cur += ' ' + line.strip()
        elif line.strip():
            got.append((None, mask(line)))
    if cur is not None:
        got.append(('b', mask(cur)))
    return got


def quotes(body):
    """`(사람…) "…"` 의 따옴표 조각을 모은다(백틱 안은 가린 채)."""
    segs = []
    for kind, text in items(body):
        m = next((m for m in LABEL.finditer(text) if AFTER.match(text, m.end())), None)
        if kind and m:
            for s in re.findall(r'"([^"]*)"', text[m.end():]):
                s = norm(s)
                if s:
                    segs.append(s)
    return segs


def bad_labels(body):
    """대조를 비켜 가는 `(사람…)` 을 모은다."""
    bad = []
    for kind, text in items(body):
        for m in LABEL.finditer(text):
            if not kind or not AFTER.match(text, m.end()) or text[m.end():].count('"') % 2:
                bad.append(show(norm(text))[:80])
                break
    return bad


def heredoc_ends(line):
    """따옴표 밖의 `<<` 에서 heredoc 끝말을 찾는다. `<<<` 는 heredoc 이 아니다."""
    ends, q, i = [], None, 0
    while i < len(line):
        c = line[i]
        if q:
            if c == '\\' and q == '"':
                i += 1
            elif c == q:
                q = None
        elif c in '\'"':
            q = c
        elif c == '\\':
            i += 1
        elif line.startswith('<<', i) and not line.startswith('<<<', i) \
                and (i == 0 or line[i - 1] != '<'):
            m = re.match(r'<<-?\s*([\'"]?)(\w+)\1', line[i:])
            if m:
                ends.append(m.group(2))
                i += m.end()
                continue
        i += 1
    return ends


def strip_heredocs(cmd):
    keep, ends = [], []
    for line in cmd.split('\n'):
        if ends:
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        keep.append(line)
        ends += heredoc_ends(line)
    return '\n'.join(keep)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''
cmd = strip_heredocs(cmd.replace('\\\n', ' '))
if not re.search(r'\bgh\s+pr\s+comment\b', cmd):
    sys.exit(0)

# ── 정규형인가 ──
line = cmd.strip()
toks = None
if '\n' not in line:
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ''
        toks = list(lex)
    except ValueError:
        toks = None
canon = (toks is not None and len(toks) >= 3
         and os.path.basename(toks[0]) == 'gh' and toks[1:3] == ['pr', 'comment']
         and not any(set(t) <= set('();<>|&') or t.startswith('#') for t in toks))
if not canon:
    posting = re.search(r'\bgh\s+pr\s+comment\b[^\n;&|]*?\s(?:%s)(?=[\s=]|$)'
                        % '|'.join(re.escape(f) for f in BODY_FLAGS), cmd)
    if posting:
        deny("본문을 넘기는 gh pr comment 는 한 줄 정규형으로 따로 쳐라: " + CANON
             + ". 다른 명령 · 줄바꿈 · 주석 · 리다이렉트 · 래퍼와 이으면 "
             "이 훅이 본문을 믿을 수 없다.")
    sys.exit(0)

args = toks[3:]
if '--help' in args or '-h' in args:
    sys.exit(0)
pr, repo, path, flags = None, None, None, []
j = 0
while j < len(args):
    a, val = args[j], None
    if '=' in a and a.startswith('--'):
        a, val = a.split('=', 1)
    if a in ('-F', '--body-file', '-b', '--body', '-R', '--repo') and val is None:
        j += 1
        val = args[j] if j < len(args) else ''
    if a in BODY_FLAGS:
        flags.append(a)
        if a in ('-F', '--body-file'):
            path = val
    elif a in ('-R', '--repo'):
        repo = val
    elif not a.startswith('-') and pr is None:
        pr = a
    j += 1

if not flags:
    sys.exit(0)                 # 본문 없이는 새 글을 안 올린다(`--delete-last` 등)
if flags != ['-F'] and flags != ['--body-file'] or not path or not os.path.isabs(path):
    deny("gh pr comment 의 본문은 절대 경로 파일 하나로만 넘긴다: " + CANON
         + ". 인라인 본문 · 표준입력 · 편집기 · 상대 경로는 이 훅이 판정할 수 없다.")
try:
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
except (OSError, UnicodeDecodeError):
    deny("gh pr comment 의 본문 파일을 읽지 못해 판정할 수 없다(없거나 UTF-8 이 아니다). "
         "UTF-8 파일을 절대 경로로 --body-file 에 넘겨라.")

if ANSWER.match(body):
    out("ask", "3.5 코멘트(「### N라운드에 사람이 준 답」)는 사람의 승인을 받고 올리는 "
               "글이다. 다음 라운드 코멘트의 (사람) 인용이 이것과 대조된다. "
               "초안을 보이고 승인받았을 때만 허락한다.")
if not ROUND.match(body):
    sys.exit(0)

bad = bad_labels(body)
if bad:
    deny("라운드 코멘트에 따옴표로 인용하지 않은 (사람) 이 있다(뒤에 따옴표 인용이 없거나 "
         "닫히지 않았거나 불릿 밖이다). (사람) 은 3.5 코멘트에 올라간 문장을 \"…\" 로 "
         "인용할 때만 쓴다. 예시는 백틱으로 감싼다. 기록이 없으면 셀프+ 로 쓴다. 해당 줄: "
         + " / ".join(bad))
want = quotes(body)
if not want:
    sys.exit(0)

gh = ['gh', 'pr', 'view'] + ([pr] if pr else []) + (['-R', repo] if repo else []) \
    + ['--json', 'comments', '--jq', '[.comments[].body]']
try:
    r = subprocess.run(gh, cwd=data.get('cwd') or None, capture_output=True, text=True, timeout=60)
    bodies = json.loads(r.stdout) if r.returncode == 0 else None
except (OSError, ValueError, subprocess.TimeoutExpired):
    bodies = None
if not isinstance(bodies, list):
    deny("라운드 코멘트의 (사람) 인용을 대조하려고 PR 코멘트를 읽다가 실패했다(gh). "
         "판정 못 한 것은 올리지 않는다. gh 인증과 PR 번호를 확인하고 다시 쳐라.")

have = []
for b in bodies:
    if isinstance(b, str) and ANSWER.match(b):
        have += quotes(b)
# 따옴표 안에서 가운데를 `…` 로 줄인 인용이 있다(「길면 잘라 쓰되 낱말을
# 바꾸지 않는다」). 줄인 조각들이 한 인용 안에 순서대로 있어야 한다.
missing = []
for s in want:
    pieces = [p.strip() for p in re.split(r'…|\.\.\.', s) if p.strip()]
    pat = re.compile('.*?'.join(re.escape(p) for p in pieces))
    if not any(pat.search(h) for h in have):
        missing.append(show(s))
if missing:
    deny("라운드 코멘트의 (사람) 인용 중 이 PR 의 3.5 코멘트"
         "(「### N라운드에 사람이 준 답」)의 (사람) 인용에 글자 그대로 없는 것이 있다. "
         "3.5 코멘트에 올라간 문장만 인용한다. 줄였으면 한 인용 안에서 순서대로 줄인다. "
         "없는 조각: " + " / ".join('"%s"' % s for s in missing))
sys.exit(0)
PY
