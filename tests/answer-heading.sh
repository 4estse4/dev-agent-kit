#!/usr/bin/env bash
# 3.5 코멘트의 제목이 그것을 쓰는 자리와 고르는 자리 모두에서 같은 글자인가(이슈 #84).
#
# `open-pr` 3.5 템플릿의 제목(`### N…`)이 원본이다. 훅과 스킬의 jq 는 그 제목으로 라운드 코멘트 뒤의
# 3.5 코멘트를 고른다. **한 글자만 어긋나도 그 코멘트가 조용히 사라진다** — 두 리뷰는 그것을 「답이 아직
# 없다」와 구분하지 못하고, `merge-pr` 은 결정 코멘트에서 사람의 답을 빠뜨린다. 훅은
# `tests/round-comment-quotes.sh` 가 보지만 jq 는 아무 검사도 보지 않았다.
#
# - `claude-code/` 와 `common/` 의 추적 파일에서 `### N라운드…`(제목을 적은 자리)와 `### .*라운드…`
#   (제목을 고르는 정규식)를 모두 찾아, 「라운드」부터 끝까지의 글자가 템플릿 제목과 같은지 본다.
#   끝은 따옴표 · 백틱 · 「」」 · 괄호 · 줄 끝이다
# - `SELECTORS` 의 파일마다 고르는 정규식이 하나 이상 있어야 한다. 정규식의 모양이 바뀌어 이 검사가
#   못 찾게 되면 초록이 아니라 빨강이 나야 한다
#
# **검사를 먼저 검사한다.** `MUST_FIND` 는 문제를 찾아야 하는 파일 묶음, `MUST_PASS` 는 찾으면 안 되는
# 묶음이다. 둘 중 하나라도 틀리면 파일을 보지 않고 실패한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import re, subprocess, sys

TEMPLATE = 'claude-code/skills/open-pr/SKILL.md'
SELECTORS = [
    'claude-code/hooks/round_comment_quotes.sh',
    'claude-code/agents/cold-reviewer.md',
    'claude-code/skills/merge-pr/SKILL.md',
    'claude-code/skills/open-pr/SKILL.md',
    'claude-code/skills/self-review/SKILL.md',
]
# 제목을 적은 자리(N)와 고르는 정규식(.*). 「라운드」부터 끝 글자 앞까지를 뗀다
MENTION = re.compile(r'###[ ]+(N|\.\*)(라운드[^"\'`」)\n]*)')
HEADING = re.compile(r'^### N(라운드.*?)\s*$')


def template_heading(text):
    """```markdown 블록 안의 `### N…` 줄. 3.5 템플릿의 제목이다."""
    found, inside = [], False
    for line in text.split('\n'):
        if re.match(r'^```markdown\s*$', line):
            inside = True
        elif inside and re.match(r'^```\s*$', line):
            inside = False
        elif inside and HEADING.match(line):
            found.append(HEADING.match(line).group(1))
    return found


def problems(files):
    """files: {경로: 글}. 문제 목록을 낸다."""
    out = []
    heads = template_heading(files.get(TEMPLATE, ''))
    if len(heads) != 1:
        return ['%s 의 ```markdown 블록에서 `### N…` 제목을 하나로 못 찾았다(%d개)' % (TEMPLATE, len(heads))]
    want = heads[0]
    seen = set()
    for path, text in files.items():
        for n, line in enumerate(text.split('\n'), 1):
            for m in MENTION.finditer(line):
                got = m.group(2).rstrip()
                if m.group(1) == '.*':
                    seen.add(path)
                if got != want:
                    out.append('%s:%d — 「%s」 인데 템플릿 제목은 「%s」다' % (path, n, got, want))
    for path in SELECTORS:
        if path not in seen:
            out.append('%s 에서 3.5 코멘트를 고르는 `### .*라운드…` 정규식을 못 찾았다' % path)
    return out


T = '```markdown\n### N라운드 코멘트를 읽고 사람이 정한 것\n\n본문\n```\n'
OK = 'test("^\\\\s*### .*라운드 코멘트를 읽고 사람이 정한 것")'
base = {p: OK for p in SELECTORS}
base[TEMPLATE] = T + OK
MUST_FIND = [
    ('선택자 하나가 옛 제목', dict(base, **{SELECTORS[2]: 'test("^\\\\s*### .*라운드에 사람이 준 답")'})),
    ('한 글자가 다르다', dict(base, **{SELECTORS[0]: "re.compile(r'^\\s*### .*라운드 코멘트를 읽고 사람이 정한것')"})),
    ('설명 속 제목이 옛 것', dict(base, **{SELECTORS[0]: OK + '\n# `### N라운드에 사람이 준 답` 으로 고른다'})),
    ('템플릿 제목만 바뀌었다', dict(base, **{TEMPLATE: T.replace('코멘트를 읽고 사람이 정한 것', '에 사람이 준 답') + OK})),
    ('선택자가 사라졌다', dict(base, **{SELECTORS[4]: '제목으로 고르지 않는다'})),
    ('템플릿 제목이 없다', dict(base, **{TEMPLATE: OK})),
]
MUST_PASS = [
    ('모두 같다', base),
    ('메시지 속 「」 제목', dict(base, **{SELECTORS[0]: OK + '\nout("ask", "3.5 코멘트(「### N라운드 코멘트를 읽고 사람이 정한 것」)는")'})),
    ('라운드 코멘트 소제목은 제목이 아니다', dict(base, **{TEMPLATE: base[TEMPLATE] + '\n```markdown\n### 1라운드 정리\n```\n'})),
]
bad = []
for name, files in MUST_FIND:
    if not problems(files):
        bad.append('이 묶음의 문제를 못 찾는다: ' + name)
for name, files in MUST_PASS:
    got = problems(files)
    if got:
        bad.append('이 묶음은 찾으면 안 되는데 찾았다: %s — %s' % (name, got[0]))
if bad:
    for b in bad:
        print('  ✗ ' + b)
    print('    검사가 틀렸다. 파일은 보지 않았다')
    sys.exit(1)

ls = subprocess.run(['git', '-c', 'core.quotePath=false', 'ls-files', 'claude-code', 'common'],
                    capture_output=True, text=True).stdout.split('\n')
files = {f: open(f, encoding='utf-8', errors='replace').read() for f in ls if f}
if TEMPLATE not in files:
    print('  ✗ %s 를 못 읽었다 — git ls-files 가 그 파일을 내지 않았다' % TEMPLATE)
    sys.exit(1)
found = problems(files)
for p in found:
    print('  ✗ ' + p)
if found:
    print('    %d자리. 3.5 코멘트의 제목은 템플릿 · 훅 · jq 가 같은 글자여야 한다' % len(found))
    sys.exit(1)
print('  ✓ 3.5 코멘트 제목이 모든 자리에서 같다(「%s」 · 고르는 파일 %d개 · 자체 검사 %d개)'
      % (template_heading(files[TEMPLATE])[0], len(SELECTORS), len(MUST_FIND) + len(MUST_PASS)))
PY
