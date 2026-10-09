#!/usr/bin/env bash
# 스킬이 Claude Code 의 스킬 설계대로 나뉘었는가 — `SKILL.md` 는 짧고, 보조 파일은 모두 `SKILL.md` 가 가리킨다.
#
# 이 테스트가 있는 이유: 컴팩션 뒤에는 스킬의 앞부분만 다시 붙는다(공식 문서 skills.md: "keeping the first
# 5,000 tokens of each"). `SKILL.md` 가 길면 라운드 도중에 뒷부분 절차가 컨텍스트에서 빠진다. 문서는 `SKILL.md` 를
# 500줄 아래로 두고 상세는 보조 파일로 옮기라고 한다("Keep `SKILL.md` under 500 lines"). 보조 파일은 `SKILL.md` 가
# 가리켜야 Claude 가 무엇이 들었고 언제 읽을지 안다("Reference supporting files from `SKILL.md` so Claude knows
# what each file contains and when to load it"). 보는 것:
#   · 스킬마다 `SKILL.md` 가 500줄 아래다
#   · `SKILL.md` 의 상대 링크가 가리키는 파일이 있다
#   · 스킬 디렉터리의 `.md` 가 모두 `SKILL.md` 에서 링크된다
#   · `SKILL.md` 의 상대 링크가 첫 `!` 주입보다 앞에 있다. 컴팩션 뒤 다시 붙는 내용은 앞에서부터 남고 뒤가
#     잘린다(나누기 전 `open-pr` 은 헤드리스 세션에서 3.4 한가운데서 잘렸다). 주입 출력은 실행마다 길이가 달라,
#     링크가 주입 뒤에 있으면 출력이 길 때 어느 파일을 읽을지가 잘리는 쪽에 놓인다
#   · 보조 파일이 있는 스킬은 `SKILL.md` 에 `## 꼭 지킬 것` 제목을 둔다. 보조 파일이 없는 짧은 스킬은 이 검사를
#     건너뛴다. 제목을 글자로 찾으므로 이름이나 수준을 바꾸면 이 테스트가 실패한다 — 바꾼 제목을 「제목이 없는 스킬」로 보고
#     건너뛰면, 그 절이 주입 뒤로 옮겨져도 아래 검사가 알리지 않는다
#   · `## 꼭 지킬 것` 제목이 첫 `!` 주입보다 앞에 있다. 까닭은 링크와 같다 — 늘 지킬 것이 잘리는 쪽에 놓이지
#     않게 한다. 이 제목에는 링크가 없어 링크 검사가 지키지 못한다
#   · frontmatter 에 `description` 이 있고, `description` 과 `when_to_use` 를 합친 길이가 1,536자 아래다. 스킬
#     목록에는 그 둘이 이어 붙어 실리고 1,536자에서 잘린다(공식 문서 skills.md: "the combined `description` and
#     `when_to_use` text is truncated at 1,536 characters in the skill listing"). 잘리면 언제 부르는지가 사라진다
#   · 보조 파일이 있는 스킬은 `when_to_use` 를 둔다. 긴 절차를 단계마다 나눈 스킬이라, 무엇을 하는지만 적은
#     `description` 으로는 Claude 가 언제 불러야 하는지를 알 수 없다(이슈 #188 기준 6)
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import glob, os, re, sys

LIMIT = 500
LISTING = 1536
fail = 0


def ok(m):
    print('  ✓ ' + m)


def bad(m):
    global fail
    fail = 1
    print('  ✗ ' + m)


def frontmatter(text):
    """첫 줄의 `---` 부터 다음 `---` 까지를 `키: 값` 으로 읽는다. 따옴표는 벗긴다. 없으면 None."""
    lines = text.split('\n')
    if not lines or lines[0].strip() != '---':
        return None
    out = {}
    for l in lines[1:]:
        if l.strip() == '---':
            return out
        m = re.match(r'([A-Za-z_-]+):\s*(.*)$', l)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            out[m.group(1)] = v
    return None


def problems(d):
    out = []
    text = open(os.path.join(d, 'SKILL.md'), encoding='utf-8').read()
    fm = frontmatter(text)
    if fm is None:
        out.append('SKILL.md 의 frontmatter(`---` 로 감싼 첫 블록)를 읽지 못했다')
        fm = {}
    if not fm.get('description'):
        out.append('frontmatter 에 description 이 없다')
    listed = len(fm.get('description', '')) + len(fm.get('when_to_use', ''))
    if listed >= LISTING:
        out.append('description 과 when_to_use 를 합쳐 %d자다(%d자 아래여야 스킬 목록에서 잘리지 않는다)' % (listed, LISTING))
    n = len(text.splitlines())
    if n >= LIMIT:
        out.append('SKILL.md 가 %d줄이다(%d줄 아래여야 한다)' % (n, LIMIT))
    # 코드 블록과 인라인 코드 안의 `[…](…)` 는 링크가 아니다
    plain = re.sub(r'(?ms)^```.*?^```', '', text)
    plain = re.sub(r'`[^`\n]*`', '', plain)
    links = set()
    for m in re.finditer(r'\]\(([^)\s]+)\)', plain):
        target = m.group(1).split('#', 1)[0]
        if not target or re.match(r'[a-z]+:', target):
            continue
        links.add(os.path.normpath(target))
        if not os.path.isfile(os.path.join(d, target)):
            out.append('SKILL.md 가 가리키는 %s 가 없다' % target)
    support = [os.path.relpath(f, d) for f in sorted(glob.glob(os.path.join(d, '**', '*.md'), recursive=True))]
    support = [rel for rel in support if rel != 'SKILL.md']
    for rel in support:
        if rel not in links:
            out.append('%s 를 SKILL.md 가 가리키지 않는다' % rel)
    lines = text.split('\n')
    inj = next((i for i, l in enumerate(lines) if l.startswith('!`')), None)
    head, fence = None, False
    for i, l in enumerate(lines):
        if l.startswith('```'):
            fence = not fence
        elif not fence and l.rstrip() == '## 꼭 지킬 것':
            head = i
            break
    if support and head is None:
        out.append('보조 파일이 있는데 SKILL.md 에 「## 꼭 지킬 것」 제목이 없다')
    if support and not fm.get('when_to_use'):
        out.append('보조 파일이 있는데 frontmatter 에 when_to_use 가 없다 — 언제 부르는지를 적는다')
    if inj is not None and head is not None and head > inj:
        out.append('SKILL.md %d줄의 「꼭 지킬 것」이 첫 주입(%d줄)보다 뒤에 있다' % (head + 1, inj + 1))
    if inj is not None:
        fence = False
        for i, l in enumerate(lines):
            if l.startswith('```'):
                fence = not fence
                continue
            if fence or i < inj:
                continue
            for m in re.finditer(r'\]\(([^)\s]+)\)', re.sub(r'`[^`\n]*`', '', l)):
                target = m.group(1).split('#', 1)[0]
                if target and not re.match(r'[a-z]+:', target):
                    out.append('SKILL.md %d줄의 링크 %s 가 첫 주입(%d줄)보다 뒤에 있다' % (i + 1, target, inj + 1))
    return out


dirs = sorted(os.path.dirname(p) for p in glob.glob('claude-code/skills/*/SKILL.md'))
if not dirs:
    bad('claude-code/skills/*/SKILL.md 에 해당하는 파일이 없다 — 경로가 바뀌었나')
    sys.exit(1)
for d in dirs:
    name = os.path.basename(d)
    got = problems(d)
    if got:
        for g in got:
            bad('%s: %s' % (name, g))
    else:
        ok('%s 의 SKILL.md 가 %d줄 아래이고 보조 파일을 모두 가리키며, 스킬 목록에 실릴 글이 %d자 아래다'
           % (name, LIMIT, LISTING))
sys.exit(fail)
PY
