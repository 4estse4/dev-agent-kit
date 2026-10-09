#!/usr/bin/env bash
# `common/docs/verification-stages.md` 의 절을 번호로 가리키는가.
#
# **절 제목을 문장째 「」 로 인용해 가리키면 제목을 고칠 때마다 인용이 거짓이 된다.** 인용이
# 사본이 되어 두 벌이 된다(이슈 #56). 그래서 절에 번호를 붙이고 참조는 번호로 한다.
#
# **번호가 밀리면 참조는 이 테스트를 통과한 채로 다른 절을 가리킨다.** 그래서 (번호, 제목) 을 아래
# `SECTIONS` 에 고정한다. 사본은 여기 한 벌이다. 절을 더하거나 제목을 고치면 이 목록도 같이
# 고친다. 번호를 어떻게 매기는지는 그 문서 머리의 규칙을 따른다. 보는 것:
# - 그 문서의 `##` · `###` 제목이 `SECTIONS` 와 순서까지 같다. 번호가 밀리거나 겹치면 이 테스트가 실패한다
# - 파일을 가리킨 바로 뒤에 「」 인용이 오지 않는다(`verification-stages.md` 의 「…」)
# - 옛 문장 제목이 어디에도 「」 로 남아 있지 않다. 짧은 새 제목(「이월」 같은)은 용어로도
#   쓰이므로 인용만으로는 참조와 구분할 수 없어, 옛 제목만 본다
# - 그 문서를 가리킨 뒤 오는 번호와, 그 문서 안의 「아래 · 위」 뒤 번호가 실제 절 번호다
#
# `docs/dev-log.md` 와 `tests/fixtures/` 는 그때의 기록이라 보지 않는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import re, subprocess, sys

VS = 'common/docs/verification-stages.md'
SECTIONS = [
    ('1', 'L1 으로 옮길 것'), ('2', 'L2 가 볼 것'), ('3', '콜드 리뷰어'), ('3.1', '두 리뷰'),
    ('3.2', '라운드'), ('3.3', '「누가 막나」의 어휘'), ('3.4', '라운드 사이에 이어지는 것'),
    ('3.5', '판정어와 바구니'), ('3.6', '발견'), ('3.7', '이월'), ('4', 'PR 본문'),
    ('5', 'L3 에 남기는 것'), ('6', '에이전트 밖에 두는 강제'), ('6.1', '밖으로 옮긴 검사'),
    ('6.2', '권한 규칙'), ('6.3', '승인이 필요한 행동'), ('6.4', 'git hooks 의 한계'),
    ('6.5', '검사를 둘 자리'), ('6.6', '충돌 마커'), ('6.7', '에이전트 `pre_push` 훅을 두지 않는 이유'),
]
OLD = [
    'L1로 내려야 하는데 L2에 남아있기 쉬운 것들', 'L2가 실제로 필요한 것 (기계가 못 잡음)',
    'L2를 두 번 돌리는 조건 — 콜드 리뷰어', '두 리뷰를 다 돌린다 — 서로 다른 것을 잡는다',
    '라운드는 사람이 센다', '규칙마다 누가 막나 — 어휘', '라운드 사이에 무엇이 넘어가나',
    '두 축을 섞지 마라 — 판정어와 바구니', '발견은 목록이 아니라 판단 대상이다', '이월에는 끝이 있다',
    'PR 본문은 열 때 쓰고 끝이다', 'L3(사람)에게 남기는 것 — 명시적으로', '강제는 에이전트 밖에 둔다 (핵심)',
    '검사를 밖에 옮겼다고 그 검사가 무언가를 막는 것은 아니다', '권한 규칙이 실제로 무엇을 잡나',
    '사람의 승인이 필요한 행동', 'git hooks 의 정직한 한계', '어느 검사를 어디에 둘 것인가 — 실측으로 정한다',
    '충돌 마커는 훅이 막는다', '왜 에이전트 `pre_push` 훅을 두지 않는가', 'L1 으로 내릴 것',
]
fail = 0

def bad(msg):
    global fail
    fail = 1
    print('  ✗ ' + msg)

def squash(s):
    return re.sub(r'[\s>]+', '', s)

ls = subprocess.run(['git', '-c', 'core.quotePath=false', 'ls-files'], capture_output=True, text=True).stdout.split('\n')
live = [f for f in ls if f
        and f != 'docs/dev-log.md' and not f.startswith('tests/fixtures/') and f != 'tests/section-refs.sh']
text = {f: open(f, encoding='utf-8', errors='replace').read() for f in live}

# 1. 절 제목이 고정 목록과 순서까지 같다
heads = [m.group(1) for m in re.finditer(r'(?m)^#{2,3} (.*)$', text[VS])]
pinned = ['%s %s' % p for p in SECTIONS]
nums = set(re.match(r'\d+(?:\.\d+)?', h).group(0) for h in heads if re.match(r'\d', h))
if heads != pinned:
    i = next(k for k in range(max(len(heads), len(pinned)))
             if k >= len(heads) or k >= len(pinned) or heads[k] != pinned[k])
    bad('절 제목이 SECTIONS 와 다르다 — %d번째: 문서 「%s」 · SECTIONS 「%s」'
        % (i + 1, heads[i] if i < len(heads) else '없음', pinned[i] if i < len(pinned) else '없음'))
    # 끼워 넣어 밀린 것과 끝에 붙인 것을 구분한다. 앞의 것을 보고 SECTIONS 를 문서에 맞추면
    # 번호가 밀린 채 이 테스트가 통과하고, 참조는 다른 절을 가리킨다
    at = {}
    for h in heads:
        m = re.match(r'(\d+(?:\.\d+)?) (.*)$', h)
        if m:
            at[m.group(2)] = m.group(1)
    moved = ['「%s」 %s → %s' % (t, n, at[t]) for n, t in SECTIONS if t in at and at[t] != n]
    if moved:
        bad('번호가 바뀌었다 — %s. 번호는 바꾸지 않는다(그 문서 머리). SECTIONS 를 문서에 맞추지 마라'
            % ' · '.join(moved))
else:
    print('  ✓ 절 제목이 SECTIONS 와 순서까지 같다(%d개)' % len(heads))

# 2. 파일을 가리킨 바로 뒤에 「」 인용이 오지 않는다
quoted = []
for f, s in text.items():
    flat = re.sub(r'\s*\n\s*(?:>\s*)?', ' ', s)
    for m in re.finditer(r'verification-stages(?:\.md)?`?\s*(?:의\s*)?「([^」]{1,60})」', flat):
        quoted.append('%s: 「%s」' % (f, m.group(1)))
if quoted:
    bad('파일 뒤에 제목을 인용한 참조 %d건 — 예: %s' % (len(quoted), quoted[0]))
else:
    print('  ✓ 파일 뒤에 제목을 인용한 참조가 없다')

# 3. 옛 문장 제목이 「」 로 남아 있지 않다
left = []
for t in OLD:
    key = '「' + squash(t) + '」'
    for f, s in text.items():
        n = squash(s).count(key)
        if n:
            left.append('%s ×%d 「%s」' % (f, n, t))
if left:
    bad('옛 제목 인용 %d자리 — 예: %s' % (len(left), left[0]))
else:
    print('  ✓ 옛 문장 제목 인용이 없다')

# 4. 번호 참조가 실제 절이다
dangling = []
for f, s in text.items():
    flat = re.sub(r'\s*\n\s*(?:>\s*)?', ' ', s)
    # 문장 끝 마침표(`3.6.`)는 번호가 아니다. 뒤를 `[\d.]` 로 막으면 그 참조를 통째로 놓친다
    for m in re.finditer(r'verification-stages(?:\.md)?`?\s*(?:의\s*)?(\d+(?:\.\d+)?)(?!\d|\.\d)', flat):
        if m.group(1) not in nums:
            dangling.append('%s: %s' % (f, m.group(1)))
    if f == VS:
        for m in re.finditer(r'(?:아래|위)\s+(\d+(?:\.\d+)?)(?!\d|\.\d|\s*(?:줄|번|개|라운드))', flat):
            if m.group(1) not in nums:
                dangling.append('%s: %s(아래 · 위)' % (f, m.group(1)))
if dangling:
    bad('없는 절 번호를 가리킨다 %d건 — 예: %s' % (len(dangling), dangling[0]))
else:
    print('  ✓ 번호 참조가 모두 실제 절이다')

if fail == 0:
    print('  ✓ verification-stages 의 절을 번호로 가리킨다')
sys.exit(fail)
PY
