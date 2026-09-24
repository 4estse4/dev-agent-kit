#!/usr/bin/env bash
# 킷 파일이 영어를 옮긴 동사와 「지적」 · 「실측」을 쓰지 않는가.
#
# 규칙은 킷 `CLAUDE.md` 의 「언어」 절에 있고, 여기는 그 규칙을 검사만 한다(이슈 #56).
# **바꿀 말은 검사가 정하지 않는다.** 한 낱말도 자리마다 뜻이 다르므로 찾아서 알리기만 한다.
#
# - 대상은 추적 파일 전부다. `docs/dev-log.md` 와 `tests/fixtures/` 는 그때의 기록이라 빼고,
#   이 파일은 찾는 말을 적어 두므로 뺀다
# - 줄바꿈과 줄 머리의 `>` · `#` 를 공백으로 바꿔 한 줄로 이은 뒤 찾는다. 낱말 사이에서 줄이
#   바뀐 자리도 검색 결과에 나온다
# - `ALLOW` 의 글자를 먼저 지운 뒤 찾는다. 글자 그대로 일치하는 것만 허용한다. 「」 안에 쓴
#   낱말은 `PATTERNS` 의 이름 그대로인 꼴만 허용하고, 「세웠다」처럼 글자가 다르면 허용하지 않는다
# - **활용형을 하나씩 늘어놓지 않고 어간으로 찾는다.** 늘어놓은 목록은 「재보니」 · 「선 규칙」 ·
#   「재고,」처럼 목록 밖의 꼴을 지나쳐서, 규칙을 어긴 자리가 남았는데도 통과했다. 「재현 ·
#   재설치」 같은 한자어와 글자가 같은 두 글자 꼴(「재고」 · 「재지」 등)만 뒤에 한글이 없을 때로
#   좁힌다. 앞 글자가 한글이면 다른 낱말(「부재」 · 「문서면」 · 「앞세워」)이라 찾지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import re, subprocess, sys

PATTERNS = [
    ('지적', r'지적'),
    ('서다', r'(?<![가-힣])(?:섰|서다|서면|서야|서지|서고|서게|서는|선다|설 (?=[가-힣])|선 (?=[가-힣]))'),
    ('세우다', r'(?<![가-힣])(?:세우|세운|세웠|세워|세울|세웁)'),
    ('받치다', r'받치|받쳐|받친|받칠'),
    ('재다', r'(?<![가-힣])(?:쟀|잰|잴|재어|재봐|재봤|재본|재보|재려|재 [보봐봤볼]'
             r'|재(?:다|고|서|야|면|지|는|기)(?![가-힣]))'),
    ('실측', r'실측'),
]
ALLOW = [
    # 「계획을 세우다」는 우리말에서 원래 쓰는 결합이다. 활용형(세웠다 · 세운 뒤 …)도 모두 허용한다
    '계획을 세',
    # `open-pr` 이 옮긴 사람의 말이다. 인용은 낱말을 바꾸지 않는다
    '"지적 받은데',
    # `tests/section-refs.sh` 의 옛 제목 목록이다. 옛 제목과 글자가 같아야 한다
    '어느 검사를 어디에 둘 것인가 — 실측으로 정한다',
    # 규칙을 설명하려고 「」 안에 쓴 낱말 자체
    '「지적」', '「서다」', '「세우다」', '「받치다」', '「재다」', '「실측」',
]
SKIP = {'docs/dev-log.md', 'tests/term-rules.sh'}

ls = subprocess.run(['git', '-c', 'core.quotePath=false', 'ls-files'],
                    capture_output=True, text=True).stdout.split('\n')
files = [f for f in ls if f and f not in SKIP and not f.startswith('tests/fixtures/')]
if not files:
    print('  ✗ 검사할 파일이 없다 — git ls-files 가 빈 목록을 냈다')
    sys.exit(1)

found = {name: [] for name, _ in PATTERNS}
for f in files:
    s = open(f, encoding='utf-8', errors='replace').read()
    flat = re.sub(r'\s*\n\s*(?:[>#]+\s*)?', ' ', s)
    for a in ALLOW:
        flat = flat.replace(a, ' ' * len(a))
    for name, pat in PATTERNS:
        for m in re.finditer(pat, flat):
            ctx = flat[max(0, m.start() - 20):m.end() + 20].strip()
            found[name].append('%s: …%s…' % (f, ctx))

fail = 0
for name, _ in PATTERNS:
    hits = found[name]
    if hits:
        fail = 1
        print('  ✗ 「%s」 %d자리가 검색 결과에 나왔다 — 예: %s' % (name, len(hits), hits[0]))
if fail:
    print('    바꿀 말은 자리마다 뜻대로 정한다. 규칙은 CLAUDE.md 의 「언어」 절에 있다')
else:
    print('  ✓ 영어를 옮긴 동사와 「지적」 · 「실측」이 없다(파일 %d개)' % len(files))
sys.exit(fail)
PY
