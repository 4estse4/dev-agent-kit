#!/usr/bin/env bash
# PreToolUse(Bash): 라운드 코멘트의 `(사람)` 인용이 그 PR 의 3.5 코멘트에 글자 그대로 있는지 본다.
# 없으면 그 `gh pr comment` 를 막는다. 3.5 코멘트에는 사람에게 묻게 한다. 필요: python3 · gh
#
# **왜 훅인가.** 라운드 코멘트는 사람의 승인 없이 올라간다(`open-pr` 3.4). 그 코멘트에서
# 다음 라운드의 두 리뷰가 다시 판정하지 않는 것은 `(사람)` 인용 하나다. 그 대조를 스킬 안에
# 두면 모델이 안 따를 때 사라지므로 모델 밖인 여기 둔다. 근거는
# `docs/process/verification-stages.md` 의 「사람의 승인이 필요한 행동」.
#
# **무엇을 막나.** 라운드 코멘트(첫 줄 `## 리뷰 `)의 접히지 않은 부분에서
# - `(사람…) "…"` 의 따옴표 조각이 3.5 코멘트의 `(사람)` 인용 어디에도 없을 때. `…` 로 줄인
#   조각들은 한 인용 안에 순서대로 있어야 한다
# - 따옴표 없는 `(사람…)` 출처 라벨. 따옴표가 없으면 대조할 것이 없어 이 훅을 비켜 간다
# - `(사람…)` 불릿의 따옴표가 닫히지 않을 때. 넘어간 줄을 못 이어 대조가 빠진다
#
# **3.5 코멘트(`### N라운드에 사람이 준 답`)에는 `"ask"` 를 낸다.** 그 코멘트가 대조의
# 원본이라, 세션이 승인 없이 올리면 원본을 스스로 만드는 셈이다. `ask` 규칙이 없는
# 레포에서도 사람이 한 번 누르게 한다.
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 `gh pr comment <N> …` 를 칠 때만 걸린다. 사람이
# 손으로 올리거나, 다른 명령(`gh api` · `gh issue comment <PR 번호>` · `gh pr -R <레포> comment`)
# 이나 래퍼(`bash -c "…"`)나 웹으로 올리면 안 걸린다. 대조의 원본인 3.5 코멘트의 인용이 진짜
# 사람 말인지는 이 훅이 모른다. 3.5 코멘트는 사람이 승인하고 올린다.
#
# **통과시킬 때 아무것도 내지 않는다.** 훅의 `"allow"` 는 권한 프롬프트를 건너뛰게 하지만
# `ask` 규칙은 그대로 평가된다(공식 문서: "Deny and ask rules … are still evaluated regardless
# of what the hook returns"). 설치된 레포의 `ask` 에 있는 `gh pr comment` 프롬프트는 그대로 뜬다.
#
# **판정 못 하면 막는다.** 본문을 못 읽거나(인라인 `$(…)` · 표준입력 · UTF-8 아님) `gh` 가
# 실패하거나 없으면 라운드 코멘트인지 인용이 맞는지 모른다. 판정 못 한 것을 통과로 치지
# 않는다.
# 본문을 넘기지 않는 호출(`--help` · `--delete-last`)은 게시하지 않으므로 건너뛴다.
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
# 불릿 머리의 출처 라벨. `- (사람) "…"` · `- **해결** (사람, 2라운드부터) "…"`
LABEL = re.compile(r'^\s*(?:[-*]|\d+\.)\s+(?:\*\*[^*]+\*\*\s+)?\(사람[^)]*\)')
PERSON = re.compile(r'\(사람[^)]*\)\s*"')
PUNCT = set(';&|()<>\n')


def out(decision, why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


def deny(why):
    out("deny", why)


def norm(s):
    return ' '.join(s.replace('**', '').split())


def bullets(body):
    """접히지 않은 부분의 불릿을 (첫 줄, 이어 붙인 글) 로 돌려준다.

    불릿은 다음 불릿 · `→` 줄 · 빈 줄 · 들여쓰지 않은 줄에서 끝난다.
    `→` 뒤는 세션의 판단이다.
    """
    got, cur = [], None
    for line in body.split('\n'):
        if re.match(r'^<details>', line):
            break
        is_bullet = BULLET.match(line)
        if is_bullet or re.match(r'^\s*→', line) or not line.strip() \
                or not re.match(r'^\s', line):
            if cur is not None:
                got.append(cur)
            cur = [line, line] if is_bullet else None
            continue
        if cur is not None:
            cur[1] += ' ' + line.strip()
    if cur is not None:
        got.append(cur)
    return got


def quotes(body):
    """`(사람…) "…"` 불릿의 따옴표 조각을 모은다."""
    segs = []
    for _first, text in bullets(body):
        m = PERSON.search(text)
        if not m:
            continue
        for s in re.findall(r'"([^"]*)"', text[m.end() - 1:]):
            s = norm(s)
            if s:
                segs.append(s)
    return segs


def bad_labels(body):
    """라운드 코멘트에서 대조를 비켜 가는 `(사람…)` 라벨을 모은다."""
    bad = []
    for first, text in bullets(body):
        if not LABEL.match(first):
            continue
        m = PERSON.search(text)
        if not m or text[m.end() - 1:].count('"') % 2:
            bad.append(norm(first)[:80])
    return bad


def strip_heredocs(cmd):
    """heredoc 본문을 뗀다. 그 안의 글(커밋 메시지 · 초안)은 명령이 아니다."""
    lines, keep, ends = cmd.split('\n'), [], []
    for line in lines:
        if ends:
            if line.strip() == ends[0]:
                ends.pop(0)
            continue
        keep.append(line)
        ends += [m.group(2) for m in re.finditer(r'<<-?\s*([\'"]?)(\w+)\1', line)]
    return '\n'.join(keep)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''
cwd = data.get('cwd') or os.getcwd()
cmd = strip_heredocs(cmd)
if not re.search(r'\bgh\s+pr\s+comment\b', cmd):
    sys.exit(0)

try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=''.join(sorted(PUNCT)))
    lex.whitespace = ' \t\r'
    lex.whitespace_split = True
    toks = list(lex)
except ValueError:
    deny("gh pr comment 명령을 읽지 못해 라운드 코멘트인지 판정할 수 없다. "
         "`gh pr comment <N> --body-file <파일>` 한 줄로 다시 쳐라.")

calls = []
for i in range(len(toks) - 2):
    if os.path.basename(toks[i]) == 'gh' and toks[i + 1] == 'pr' and toks[i + 2] == 'comment':
        args = []
        for t in toks[i + 3:]:
            if set(t) <= PUNCT:
                break
            args.append(t)
        calls.append(args)
if not calls:
    sys.exit(0)

ask = None
for args in calls:
    if '--help' in args or '-h' in args:
        continue
    pr, repo, body, body_known, has_body = None, None, None, True, False
    j = 0
    while j < len(args):
        a, val = args[j], None
        if '=' in a and a.startswith('--'):
            a, val = a.split('=', 1)
        if a in ('-F', '--body-file', '-b', '--body', '-R', '--repo') and val is None:
            j += 1
            val = args[j] if j < len(args) else ''
        if a in ('-F', '--body-file'):
            has_body = True
            if val == '-':
                body_known = False
            else:
                try:
                    with open(os.path.join(cwd, os.path.expanduser(val)), encoding='utf-8') as fh:
                        body = fh.read()
                except (OSError, UnicodeDecodeError):
                    body_known = False
        elif a in ('-b', '--body'):
            has_body = True
            if '$' in val or '`' in val:
                body_known = False
            else:
                body = val
        elif a in ('-R', '--repo'):
            repo = val
        elif a in ('-e', '--editor', '-w', '--web'):
            has_body, body_known = True, False
        elif a.startswith('-'):
            pass
        elif pr is None:
            pr = a
        j += 1

    if not has_body:
        continue                    # 본문 없이는 새 글을 안 올린다(`--delete-last` 등)
    if not body_known or body is None:
        deny("gh pr comment 의 본문을 읽지 못해 라운드 코멘트인지 판정할 수 없다. "
             "본문을 UTF-8 파일에 쓰고 `--body-file <파일>` 로 넘겨라.")
    if ANSWER.match(body):
        ask = ("3.5 코멘트(「### N라운드에 사람이 준 답」)는 사람의 승인을 받고 올리는 "
               "글이다. 다음 라운드 코멘트의 (사람) 인용이 이것과 대조된다. "
               "초안을 보이고 승인받았을 때만 허락한다.")
        continue
    if not ROUND.match(body):
        continue
    bad = bad_labels(body)
    if bad:
        deny("라운드 코멘트에 따옴표로 인용하지 않은 (사람) 라벨이 있다"
             "(따옴표가 없거나 닫히지 않았다). (사람) 은 3.5 코멘트에 올라간 문장을 \"…\" 로 "
             "인용할 때만 쓴다. 기록이 없으면 셀프+ 로 쓴다. 해당 줄: " + " / ".join(bad))
    want = quotes(body)
    if not want:
        continue

    gh = ['gh', 'pr', 'view'] + ([pr] if pr else []) + (['-R', repo] if repo else []) \
        + ['--json', 'comments', '--jq', '[.comments[].body]']
    try:
        r = subprocess.run(gh, cwd=cwd, capture_output=True, text=True, timeout=60)
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
    # 따옴표 안에서 가운데를 `…` 로 줄인 인용이 있다(「길면 잘라 쓰되 낱말을 바꾸지
    # 않는다」). 줄인 조각들이 한 인용 안에 순서대로 있어야 한다.
    missing = []
    for s in want:
        pieces = [p.strip() for p in re.split(r'…|\.\.\.', s) if p.strip()]
        pat = re.compile('.*?'.join(re.escape(p) for p in pieces))
        if not any(pat.search(h) for h in have):
            missing.append(s)
    if missing:
        deny("라운드 코멘트의 (사람) 인용 중 이 PR 의 3.5 코멘트"
             "(「### N라운드에 사람이 준 답」)의 (사람) 인용에 글자 그대로 없는 것이 있다. "
             "3.5 코멘트에 올라간 문장만 인용한다. 줄였으면 한 인용 안에서 순서대로 줄인다. "
             "없는 조각: " + " / ".join('"%s"' % s for s in missing))
if ask:
    out("ask", ask)
sys.exit(0)
PY
