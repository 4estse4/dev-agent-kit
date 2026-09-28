#!/usr/bin/env bash
# GitHub 에 올리는 글의 템플릿이 문단을 한 줄로 쓰는가(이슈 #65).
#
# GitHub 은 코멘트 · 이슈 · PR 본문 안의 줄바꿈 하나도 줄을 바꿔 보여 준다. 레포의 `.md` 파일은
# 그것을 공백으로 다룬다. 킷 문서는 100자 근처에서 줄을 바꿔 쓰므로, 그 버릇대로 템플릿을 고치면
# 템플릿을 옮긴 글이 문장 한가운데서 끊긴다. 실제로 `open-pr` 3.5 템플릿의 첫 문장이 그렇게 끊긴 채
# 여러 PR 의 3.5 코멘트로 올라갔다.
#
# - 대상은 `open-pr` 과 `merge-pr` 의 ```` ```markdown ```` 블록이다. GitHub 에 올리는 글의 템플릿은
#   이 표시를 단다. 다른 블록(명령 · 레포에 쓰는 파일)은 보지 않는다
# - 블록 안에서 앞 줄이 비지 않았는데 이 줄이 새 블록 원소로 시작하지 않으면 줄바꿈 하나로 이어진
#   줄이다. 새 블록 원소는 목록 · 헤딩 · 표 · 인용 · 펜스 · `---` · 들여쓴 `→` · HTML 태그다.
#   `→` 줄은 목록 항목의 판단을 둘째 줄에 두는 자리라 일부러 바꾸는 줄이다
# - 문단 줄 바로 아래의 `---` 도 찾아낸다. 수평선이 아니라 앞 줄을 제목으로 만드는 밑줄이 된다
#   (`open-pr` 의 「위에 빈 줄을 둬야 앞 줄이 제목으로 안 바뀐다」). 목록 · `→` 줄 아래의 `---` 는
#   수평선이고, `---` 다음 줄은 새 문단이다
# - 줄 전체가 `<…>` 인 자리표시는 글로 세지 않는다. 실제 글에서는 지우거나 다른 것(명령 출력의
#   코드 블록 · 목록)으로 바뀐다. 한 줄 안에 든 자리표시(`리뷰한 head: <…>`)는 글이다
#
# **검사를 먼저 검사한다.** `MUST_FIND` 는 찾아야 하는 블록, `MUST_PASS` 는 찾으면 안 되는 블록이다.
# 둘 중 하나라도 틀리면 파일을 보지 않고 실패한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import re, sys

FILES = ['claude-code/skills/open-pr/SKILL.md', 'claude-code/skills/merge-pr/SKILL.md']
OPEN = re.compile(r'^```markdown\s*$')
CLOSE = re.compile(r'^```\s*$')
# 새 블록 원소로 시작하는 줄. 이 줄은 앞 줄에 이어지지 않는다
NEW = re.compile(r'^\s*(?:[-*+]\s|\d+\.\s|#|\||>|→|```|---\s*$|</?[A-Za-z])')
# 이 줄 다음 줄은 새 문단이다
ENDS = re.compile(r'^\s*(?:#|\||```|---\s*$|</?[A-Za-z])')
RULE = re.compile(r'^\s*---\s*$')
PLACEHOLDER = re.compile(r'^\s*<[^<>]*>\s*$')

MUST_FIND = [
    '```markdown\n다음 라운드가 이것을 「사람의 답을 적는\n자리」대로 옮긴다.\n```',
    '```markdown\n**위 필수를 고치는 것을 제안합니다.** 그중 셋은\n이월된 것이다.\n```',
    '```markdown\n- (콜드) 항목 하나\n  이어지는 설명\n```',
    '```markdown\n<`evidence.sh` 가 덧붙인 출력>\n새 테스트: 없음\n자동 검증이 확인하지 않은 것: 없음\n```',
    '```markdown\n리뷰한 head: <40자>\n다음 줄\n```',
    # 문단 바로 아래 `---` 는 수평선이 아니라 앞 줄을 제목으로 만든다
    '```markdown\n**다음 라운드를 제안합니다.** 근거 문장\n---\n```',
    '```markdown\n문단\n---\n```',
]
MUST_PASS = [
    '```markdown\n- (사람) "문장"\n  → 판단\n```',
    '```markdown\n첫 문단.\n\n둘째 문단.\n```',
    '```markdown\n| a | b |\n| --- | --- |\n| 1 | 2 |\n```',
    '```markdown\n**지난 코멘트 정정**\n<거짓이 있었으면 여기 적는다.>\n- 1라운드 "문장"\n  → 판단\n```',
    '```markdown\n## 제목\n본문 한 줄\n```',
    '```markdown\n<details>\n<summary>셀프 리뷰 전문</summary>\n```',
    # 목록 아래 `---` 는 수평선이고, 수평선 다음 줄은 새 문단이다
    '```markdown\n- (사람) "문장"\n  → 판단\n---\n```',
    '```markdown\n문단\n\n---\n다음 문단\n```',
    # ```markdown 블록 밖은 보지 않는다
    '```\n명령이\n여러 줄이다\n```',
    '레포 문서는\n줄을 바꿔 쓴다',
]


def joined(text):
    """```markdown 블록 안에서 앞 줄에 이어진 줄의 (줄 번호, 글)과 본 블록 수를 낸다."""
    hits, blocks, inside, prev = [], 0, False, ''
    for n, line in enumerate(text.split('\n'), 1):
        if not inside:
            if OPEN.match(line):
                inside, prev, blocks = True, '', blocks + 1
            continue
        if CLOSE.match(line):
            inside = False
            continue
        if PLACEHOLDER.match(line):
            prev = ''
            continue
        if line.strip() and prev.strip() and not NEW.match(line) and not ENDS.match(prev):
            hits.append((n, '앞 줄에 이어진다: ' + line.strip()[:60]))
        # 문단 줄 바로 아래 `---` 는 그 줄을 제목으로 만든다. 목록 · `→` 줄 아래면 수평선이다
        elif RULE.match(line) and prev.strip() and not NEW.match(prev) and not ENDS.match(prev):
            hits.append((n, '문단 바로 아래 `---` 라 앞 줄이 제목이 된다. 사이에 빈 줄을 둔다'))
        prev = line
    return hits, blocks


bad = []
for text in MUST_FIND:
    if not joined(text)[0]:
        bad.append('이 블록의 이어진 줄을 못 찾는다: %r' % text)
for text in MUST_PASS:
    got = joined(text)[0]
    if got:
        bad.append('이 블록은 찾으면 안 되는데 %d번째 줄을 찾았다: %r' % (got[0][0], text))
if bad:
    for b in bad:
        print('  ✗ ' + b)
    print('    검사가 틀렸다. 파일은 보지 않았다')
    sys.exit(1)

found, total = [], 0
for f in FILES:
    hits, blocks = joined(open(f, encoding='utf-8').read())
    total += blocks
    found += [(f, n, t) for n, t in hits]
if total == 0:
    print('  ✗ ```markdown 블록을 하나도 못 찾았다 — 템플릿의 펜스 표시가 바뀌었으면 이 검사도 고친다')
    sys.exit(1)
for f, n, t in found:
    print('  ✗ %s:%d — %s' % (f, n, t))
if found:
    print('    %d자리. GitHub 은 이 줄바꿈을 그대로 보여 준다. 문단과 목록 항목을 한 줄로 쓴다' % len(found))
    sys.exit(1)
print('  ✓ GitHub 템플릿의 문단이 한 줄이다(블록 %d개 · 자체 검사 %d개)' % (total, len(MUST_FIND) + len(MUST_PASS)))
PY
