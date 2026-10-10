#!/usr/bin/env bash
# PreToolUse(Bash): 라운드 코멘트의 `(사람)` 인용이 그 PR 의 사람 계정 코멘트에 글자 그대로 있는지 본다.
# 없으면 그 `gh pr comment` 를 막는다. 필요: python3 · gh
#
# **원본은 사람 계정 코멘트다.** 봇 설정(`.claude/bot.json`)이 있으면 세션은 봇 계정으로 쓰고 사람은 자기
# 계정으로 결정을 남기므로, 쓰기 권한이 있는 사람 계정의 코멘트가 원본이다 — 창에서 고른 보기로 만든
# `- 주제: 보기` 줄(`human_comment.sh`)이거나 사람이 PR 웹에서 쓴 글이다. 어느 코멘트가 원본인지는
# `human_review.sh sources` 가 고른다. 원본의 단위는 `>` 로 시작하는 줄을 뺀 불릿 하나나 줄 하나다 —
# `>` 줄은 Quote reply 로 인용해 넣은 남의 글(대개 봇의 라운드 코멘트)이고, 서로 다른 줄의 조각을 이은
# 인용은 사람이 쓴 적 없는 문장이다. **봇 설정이 없으면 `(사람)` 인용이 든 라운드 코멘트를 막는다** —
# 세션과 사람이 한 계정이라 글쓴이로 사람의 글을 가려낼 수 없어 원본이 없다. 킷은 봇과 함께 쓴다.
#
# **왜 훅인가.** 라운드 코멘트는 사람의 승인 없이 올라간다(`open-pr` 3.4). 그 코멘트에서
# 다음 라운드의 두 리뷰가 다시 판정하지 않는 것은 `(사람)` 인용 하나다. 그 대조를 스킬 안에
# 두면 모델이 안 따를 때 사라지므로 모델 밖인 여기 둔다. 근거는
# `docs/process/verification-stages.md` 6.3.
#
# **명령 글자 어디에든 `gh pr comment` 가 보이면 한 줄 정규형만 받는다.**
#
#     gh pr comment <N> [-R <레포>] --body-file <절대 경로>
#
# 앞에 무엇이 오든(`if` · `timeout` · `env` · `bash -lc` · `find -exec` · `xargs`), 따옴표나
# heredoc 안이든 가리지 않는다. `\` 줄넘김만 공백으로 잇는다. 그 밖의 모양 — 다른 명령 ·
# 줄바꿈 · 주석 · 리다이렉트 · 래퍼 · 모르는 플래그 · URL 이나 브랜치로 적은 PR — 은 게시인지
# 가리지 않고 막는다. 게시인지, 명령 자리인지 해석해서 가리던 동안 라운드마다 새 우회가 나왔다.
# 대가로 그 글자가 든 검색 · 커밋 메시지 · heredoc 도 막히고, 막힌 까닭을 적은 글이 명령을 어떻게
# 바꾸면 되는지 알려 준다.
# 플래그는 gh 도움말의 목록 그대로이고, 값을 받는 `-F` · `-R` 은 붙인 모양(`-Fx` · `-F=x`)도
# 값으로 읽는다. 경로는 절대 경로만 받는다 — 명령 안의 `cd` 를 이 훅이 못 따라간다. 본문 없는
# 호출(`--help` · `--delete-last`)은 게시가 아니라서 건너뛴다.
#
# **라운드 코멘트(첫 줄 `## 리뷰 `)에서 무엇을 막나.** 접힌 블록(`<details>`)을 뺀 부분에서
# - `(사람…) "…"` 의 따옴표 조각이 원본 어디에도 없을 때. `…` 로 줄인 조각들은 원본의 한 단위(불릿
#   하나나 줄 하나) 안에 순서대로 있어야 한다
# - 백틱 밖의 `(사람…)` 바로 뒤에 따옴표 인용이 없거나, 따옴표가 닫히지 않을 때.
#   대조할 인용이 없어 이 훅의 대조가 우회된다. 백틱 안은 예시라서 안 본다
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 실행할 때만 작동한다. 사람이 손으로 올리거나 웹으로
# 올리면 훅이 불리지 않고, 다른 명령(`gh api` · `gh issue comment <PR 번호>`)으로 올리면 알아보지 못한다. 명령 이름을
# 꾸며도(변수 `$GH` · 별칭 · 함수 · 낱말 안의 따옴표나 `\` 인 `comm""ent` · `co\mment`) 못
# 알아보고, 게시 명령을 스크립트 파일에 두고 실행하거나 인라인 인터프리터에 인자 목록으로
# 전달해도(`python3 -c` · `node -e` 의 `['gh', 'pr', 'comment', …]`) 못 본다 — 이 훅은 형식대로 입력한
# 게시 명령의 실수를 막고, 작정한 우회는 막으려 하지 않는다. 원본의 글쓴이는 GitHub 이 기록하므로,
# 세션이 봇 계정으로 올린 글은 원본이 되지 못한다.
#
# **통과시킬 때 아무것도 내지 않는다.** 훅의 `"allow"` 는 권한 프롬프트를 건너뛰게 하지만
# `ask` 규칙은 그대로 평가된다(공식 문서: "Deny and ask rules … are still evaluated regardless
# of what the hook returns"). 설치된 레포의 `ask` 에 있는 `gh pr comment` 프롬프트는 그대로 표시된다.
#
# **판정 못 하면 막는다.** 본문 파일을 못 읽거나(없음 · UTF-8 아님) `gh` 가 실패하거나 없으면
# 라운드 코멘트인지 인용이 맞는지 모른다. 판정 못 한 것을 통과로 처리하지 않는다.
# **이 스크립트가 실행되지 못하면 막지 못한다.** `python3` 가 없거나, 시간을 초과하거나, 파일이 없으면
# 훅이 오류로 끝나고 문서대로 호출은 그대로 진행된다. `ask` 에 `gh pr comment` 가 없는
# 레포에서는 그 라운드 코멘트가 대조 없이 나간다. 판정 못 해 막는 위의 경우와 다르다.
#
# **제목 앵커는 스킬과 같은 글자다.** 라운드 코멘트는 첫 줄 `## 리뷰 ` 로 고른다. 제목을 바꾸면 이
# 파일도 같이 바꾼다 — 그 제목을 쓰는 스킬들과 같은 `git grep` 결과에 나온다.
input=$(cat)

# 모든 Bash 호출마다 실행되므로, `comment` 가 없는 호출은 파이썬을 실행하지 않고 끝낸다.
case "$input" in
  *comment*) ;;
  *) exit 0 ;;
esac

# 공유 파일(round_comment_cmd.py)을 읽어도 훅 디렉터리에 __pycache__ 를 남기지 않는다.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, re, subprocess, sys

ROUND = re.compile(r'^\s*## 리뷰 ')
BULLET = re.compile(r'^\s*(?:[-*]|\d+\.)\s')
# 출처 라벨은 `(사람)` 과 `(사람, N라운드부터)` 둘뿐이다.
# `(사람이 연다)` 같은 괄호 글은 라벨이 아니다.
LABEL = re.compile(r'\(사람(?:\s*,[^)]*)?\)')
AFTER = re.compile(r'(?:\*\*)?\s*"')          # 라벨 바로 뒤. `**(사람)** "…"` 도 인용이다
QMASK, LMASK = '＂', '(사​람'       # 백틱 안의 `"` 와 `(사람` 을 가린다


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
    """대조를 받지 않는 `(사람…)` 을 모은다."""
    bad = []
    for kind, text in items(body):
        for m in LABEL.finditer(text):
            if not kind or not AFTER.match(text, m.end()) or text[m.end():].count('"') % 2:
                bad.append(show(norm(text))[:80])
                break
    return bad


# 명령을 읽는 규칙은 콜드 대조 훅(round_comment_cold.sh)과 같이 쓰는 kit/round_comment_cmd.py 에 있다.
# 두 훅이 받는 게시 모양이 한 벌이어야 한쪽이 받는 모양이 다른 쪽의 대조를 피해 가지 않는다.
sys.path.insert(0, os.path.join(os.environ['HOOK_DIR'], 'kit'))
import round_comment_cmd  # noqa: E402

try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
kind, got = round_comment_cmd.parse((data.get('tool_input') or {}).get('command') or '')
if kind in ('none', 'skip'):
    sys.exit(0)
if kind == 'deny':
    deny(got)
pr, repo, path = got['pr'], got['repo'], got['path']
try:
    with open(path, encoding='utf-8') as fh:
        body = fh.read()
except (OSError, UnicodeDecodeError):
    deny("gh pr comment 의 본문 파일을 읽지 못해 판정할 수 없다(없거나 UTF-8 이 아니다). "
         "UTF-8 파일을 --body-file 에 전달해라.")

if not ROUND.match(body):
    sys.exit(0)

bad = bad_labels(body)
if bad:
    deny("라운드 코멘트에 따옴표로 인용하지 않은 (사람) 이 있다(뒤에 따옴표 인용이 없거나 "
         "닫히지 않았거나 불릿 밖이다). (사람) 은 이 PR 의 사람 계정 코멘트에 있는 글자를 \"…\" 로 "
         "인용할 때만 쓴다. 예시는 백틱으로 감싼다. 기록이 없으면 셀프+ 로 쓴다. 해당 줄: "
         + " / ".join(bad))
want = quotes(body)
if not want:
    sys.exit(0)

top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=data.get('cwd') or None,
                     capture_output=True, text=True)
if not (top.returncode == 0 and os.path.isfile(os.path.join(top.stdout.strip(), '.claude', 'bot.json'))):
    deny("이 레포에는 봇 설정(.claude/bot.json)이 없어, 라운드 코멘트의 (사람) 인용을 대조할 원본이 없다. "
         "원본은 사람 계정 코멘트인데, 봇 설정이 없으면 세션과 사람이 한 계정이라 글쓴이로 사람의 글을 "
         "가려낼 수 없다. 킷은 봇과 함께 쓴다 — 켜는 법은 docs/process/kit-guide.md 의 「봇 계정과 사람의 "
         "승인」 절에 있다. 그 전까지는 (사람) 인용 없이 올린다.")

# 원본은 판정 스크립트가 고른다. `merge-pr` 이 같은 스크립트로 Approve 를 판정한다 — 사람 계정을
# 알아보는 기준이 두 벌이면 어긋난다.
judge = ['bash', os.path.join(os.environ['HOOK_DIR'], 'human_review.sh'), 'sources', pr] \
    + (['-R', repo] if repo else [])
try:
    r = subprocess.run(judge, cwd=data.get('cwd') or None, capture_output=True, text=True,
                       timeout=100)
    got = json.loads(r.stdout) if r.returncode == 0 else None
except (OSError, ValueError, subprocess.TimeoutExpired):
    got = None
if not isinstance(got, dict) or not isinstance(got.get('comments'), list):
    deny("라운드 코멘트의 (사람) 인용을 대조하려고 PR 코멘트를 읽다가 실패했다(gh). "
         "판정 못 한 것은 올리지 않는다. gh 인증과 PR 번호를 확인하고 다시 입력해라.")

# 사람 계정 코멘트가 원본이다 — 창에서 고른 보기로 만든 `- 주제: 보기` 줄이거나, 사람이 PR 웹에서 쓴 글이다.
# 원본의 단위는 불릿 하나(이어지는 들여쓴 줄 포함) 또는 불릿 밖의 줄 하나다. 한 줄이 결정 하나라서, 서로 다른
# 결정의 조각을 `…` 로 잇거나 순서를 바꾼 인용이 통과하지 않게 한다.
have, edited = [], []
for c in got['comments']:
    b = c.get('body') if isinstance(c, dict) else None
    if not isinstance(b, str):
        if isinstance(c, dict) and c.get('why'):
            edited.append('%s (%s)' % (c.get('url'), c['why']))
        continue
    # `> …` 줄은 Quote reply 로 인용해 넣은 남의 글(대개 봇의 라운드 코멘트)이다
    have += [norm(t) for _, t in items('\n'.join(l for l in b.split('\n') if not l.lstrip().startswith('>')))]
# 따옴표 안에서 가운데를 `…` 로 줄인 인용이 있다(「길면 잘라 쓰되 낱말을
# 바꾸지 않는다」). 줄인 조각들이 한 인용 안에 순서대로 있어야 한다.
missing = []
for s in want:
    pieces = [p.strip() for p in re.split(r'…|\.\.\.', s) if p.strip()]
    pat = re.compile('.*?'.join(re.escape(p) for p in pieces))
    if not any(pat.search(h) for h in have):
        missing.append(show(s))
if missing:
    deny("라운드 코멘트의 (사람) 인용 중 이 PR 의 사람 계정 코멘트에 글자 그대로 없는 것이 있다. "
         "쓰기 권한이 있는 사람 계정의 코멘트만 원본이고, > 인용 줄을 뺀 불릿 하나나 줄 하나가 원본의 단위다. "
         "봇 계정으로 올린 글은 원본이 아니다. 줄였으면 한 불릿(줄) 안에서 순서대로 줄인다. "
         "없는 조각: " + " / ".join('"%s"' % s for s in missing)
         + (" 다른 계정이 고쳐 원본에서 뺀 코멘트: " + " / ".join(edited) if edited else ""))
sys.exit(0)
PY
