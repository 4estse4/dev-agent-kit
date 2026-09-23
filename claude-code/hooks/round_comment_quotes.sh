#!/usr/bin/env bash
# PreToolUse(Bash): 라운드 코멘트의 `(사람)` 인용이 그 PR 의 3.5 코멘트에 글자 그대로 있는지 본다.
# 없으면 그 `gh pr comment` 를 막는다. 필요: python3 · gh
#
# **왜 훅인가.** 라운드 코멘트는 사람의 승인 없이 올라간다(`open-pr` 3.4). 그 코멘트에서
# 다음 라운드의 두 리뷰가 다시 판정하지 않는 것은 `(사람)` 인용 하나다. 그 대조를 스킬 안에
# 두면 모델이 안 따를 때 사라지므로 모델 밖인 여기 둔다. 근거는
# `docs/process/verification-stages.md` 의 「사람의 승인이 필요한 행동」.
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 `gh pr comment` 를 칠 때만 걸린다. 사람이 손으로
# 올리거나, 다른 도구(`gh api` · 웹)로 올리면 안 걸린다. 그리고 대조의 원본인 3.5 코멘트의
# 인용이 진짜 사람 말인지는 이 훅이 모른다. 3.5 코멘트는 사람이 승인하고 올린다.
#
# **막기만 한다.** 통과시킬 때 아무것도 내지 않는다. `"allow"` 를 내도 권한 규칙의 `ask` 는 못
# 넘는다(공식 문서: "allow" lets the tool call proceed to permission rules). 설치된 레포의
# `ask` 에 있는 `gh pr comment` 프롬프트는 그대로 뜬다.
#
# **판정 못 하면 막는다.** 본문을 못 읽거나(인라인 `$(…)` · 표준입력) `gh` 가 실패하거나
# 없으면 라운드 코멘트인지 인용이 맞는지 모른다. 판정 못 한 것을 통과로 치지 않는다.
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
PERSON = re.compile(r'\(사람[^)]*\)\s*"')
OPS = {';', '&&', '||', '|', '&', '(', ')', ';;', '|&'}


def deny(why):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


def quotes(body):
    """접히지 않은 부분의 `(사람…) "…"` 불릿에서 따옴표 조각을 모은다.

    불릿은 다음 불릿 · `→` 줄 · 빈 줄 · 들여쓰지 않은 줄에서 끝난다. `→` 뒤는 세션의
    판단이라 인용이 아니다.
    """
    out, cur = [], None
    for line in body.split('\n'):
        if re.match(r'^<details>', line):
            break
        is_bullet = re.match(r'^\s*[-*]\s', line)
        if is_bullet or re.match(r'^\s*→', line) or not line.strip() \
                or not re.match(r'^\s', line):
            if cur is not None:
                out.append(cur)
            cur = None
            if is_bullet:
                m = PERSON.search(line)
                if m:
                    cur = line[m.end() - 1:]
            continue
        if cur is not None:
            cur += ' ' + line.strip()
    if cur is not None:
        out.append(cur)
    segs = []
    for text in out:
        for s in re.findall(r'"([^"]*)"', text):
            s = norm(s)
            if s:
                segs.append(s)
    return segs


def norm(s):
    return ' '.join(s.replace('**', '').split())


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''
cwd = data.get('cwd') or os.getcwd()
if not re.search(r'\bgh\b[\s\S]*\bpr\b[\s\S]*\bcomment\b', cmd):
    sys.exit(0)

try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
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
            if t in OPS:
                break
            args.append(t)
        calls.append(args)
if not calls:
    sys.exit(0)

for args in calls:
    pr, repo, body, body_known = None, None, None, True
    j = 0
    while j < len(args):
        a = args[j]
        val = None
        if '=' in a and a.startswith('--'):
            a, val = a.split('=', 1)
        def take():
            global j
            if val is not None:
                return val
            j += 1
            return args[j] if j < len(args) else ''
        if a in ('-F', '--body-file'):
            p = take()
            if p == '-':
                body_known = False
            else:
                try:
                    with open(os.path.join(cwd, os.path.expanduser(p)), encoding='utf-8') as fh:
                        body = fh.read()
                except OSError:
                    body_known = False
        elif a in ('-b', '--body'):
            v = take()
            if '$' in v or '`' in v:
                body_known = False
            else:
                body = v
        elif a in ('-R', '--repo'):
            repo = take()
        elif a in ('-e', '--editor', '-w', '--web'):
            body_known = False
        elif a.startswith('-'):
            pass
        elif pr is None:
            pr = a
        j += 1

    if not body_known or body is None:
        deny("gh pr comment 의 본문을 읽지 못해 라운드 코멘트인지 판정할 수 없다. "
             "본문을 파일에 쓰고 `--body-file <파일>` 로 넘겨라.")
    if not ROUND.match(body):
        continue
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
    # 따옴표 안에서 가운데를 `…` 로 줄인 인용이 있다
    # (「길면 잘라 쓰되 낱말을 바꾸지 않는다」). 줄인 자리로 나눠 조각마다 찾는다.
    missing = [p for s in want for p in (x.strip() for x in re.split(r'…|\.\.\.', s))
               if p and not any(p in h for h in have)]
    if missing:
        deny("라운드 코멘트의 (사람) 인용 중 이 PR 의 3.5 코멘트"
             "(「### N라운드에 사람이 준 답」)의 (사람) 인용에 글자 그대로 없는 것이 있다. "
             "3.5 코멘트에 올라간 문장만 인용한다. "
             "없는 조각: " + " / ".join('"%s"' % s for s in missing))
sys.exit(0)
PY
