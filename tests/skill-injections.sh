#!/usr/bin/env bash
# 스킬·에이전트 정의의 `!` 주입이 낼 수 있는 모든 문자열을, 그 정의의 본문이 설명하는가.
#
# 이 테스트가 있는 이유: 주입이 네 문자열을 내는데 표는 셋만 적었고, 그 표가 넷째에 대해
# "안 나온다" 는 거짓을 적고 있었다. 읽는 쪽(모델)은 설명 없는 문자열을 받으면 지어낸다 —
# 한 자리에서는 대조할 본문이 없는데 `일치.` 를 쓰게 돼 있었다.
#
# 그리고 **말없이 자르는 주입**을 막는다. `head -200` 으로 SPEC 을 자른 자리가
# "SPEC 에 없으면 유령이니 지워라" 와 짝이어서, 200줄 뒤 요구가 통째로 지워질 수 있었다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import re, glob, sys
fail = 0
files = sorted(glob.glob('claude-code/skills/*/SKILL.md')) + sorted(glob.glob('claude-code/agents/*.md'))
for f in files:
    s = open(f).read()
    inj = re.findall(r'^!`(.*)`$', s, re.M)
    if not inj:
        continue
    bad = 0
    body = re.sub(r'^!`.*`$', '', s, flags=re.M)          # 주입 줄 자체는 설명이 아니다
    blanket = '`!!` 로 시작하면' in body
    emitted = {e for line in inj for e in re.findall(r'echo "([^"]+)"', line)}
    for e in sorted(emitted):
        # ${...} 가 든 문자열은 통째로 대조할 수 없다 — 첫 치환 앞까지를 본다
        key = e.split('${')[0].strip()
        if len(key) < 6:
            continue
        if e.startswith('!!') or key.startswith('!!'):
            if blanket or key in body:
                continue
        elif key in body:
            continue
        print(f"  ✗ {f}: 주입이 내는 `{key}…` 를 본문이 설명하지 않는다"); fail = 1; bad = 1
    # 자르면 잘랐다고 말해야 한다
    for line in inj:
        if re.search(r'\b(head|tail) -\d', line) and '!!' not in line and '...' not in line and '앞 25줄' not in line:
            print(f"  ✗ {f}: 주입이 말없이 자른다 — {line[:70]}"); fail = 1; bad = 1
    if not bad:
        print(f"  ✓ {f.split('/')[-2] if 'skills' in f else f.split('/')[-1]}: 내는 문자열 {len(emitted)}개 전부 설명됨")
sys.exit(fail)
PY
