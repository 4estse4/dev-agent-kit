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
    # **한 주입 줄이 내는 것들은 다 적히거나 다 안 적히거나여야 한다.** 그 줄의 갈래를
    # 설명하려고 표를 쓰기 시작했으면 그 줄의 갈래를 다 적어야 한다는 뜻이다. 부분만 적힌
    # 표가 통짜 규칙보다 나쁘다 — 실제로 한 줄이 넷을 내는데 표는 셋만 적고, 남은 하나에
    # 대해 "안 나온다" 는 거짓을 적고 있었다.
    partial = set()
    for line in inj:
        outs = [e.split('$')[0].strip() for e in re.findall(r'echo "([^"]+)"', line)]
        outs = [o for o in outs if len(o) >= 6]
        listed = [o for o in outs if o in body]
        if listed and len(listed) < len(set(outs)):
            partial |= {o for o in outs if o not in body}
    for e in sorted(emitted):
        # 치환($VAR · ${VAR})이 든 문자열은 통째로 대조할 수 없다 — 첫 $ 앞까지를 본다
        key = e.split('$')[0].strip()
        if len(key) < 6:
            continue
        # 포괄 규칙(`!!` 로 시작하면 멈춰라)은 **아무 문자열도 개별로 안 적은 파일**에만
        # 면제가 된다. 하나라도 개별로 적었으면 나머지도 적어야 한다 — 부분만 적힌 표가
        # 통짜 규칙보다 나쁘다. 실제로 그랬다: 주입이 넷을 내는데 표는 셋이었고, 셋째 행이
        # 넷째에 대해 "안 나온다" 는 거짓을 적고 있었다. 그 결함을 이 검사가 잡아야 한다.
        if key in body:
            continue
        if key in partial:
            print(f"  ✗ {f}: 같은 주입 줄의 다른 갈래는 적어놓고 `{key}…` 만 빠졌다"); fail = 1; bad = 1
            continue
        if key.startswith('!!') and blanket:
            continue
        print(f"  ✗ {f}: 주입이 내는 `{key}…` 를 본문이 설명하지 않는다"); fail = 1; bad = 1
    # 자르면 잘랐다고 말해야 한다
    # **자르기마다** 그것을 말하는 문구가 붙어야 한다. 줄에 `!!` 가 하나 있다고 해서 그
    # 줄의 모든 자르기가 면제되면, 이미 `!!` 를 가진 줄(예: PR 전체 diff 를 나르는 슬롯)에
    # 어떤 자르기를 넣어도 안 걸린다 — 실측으로 `| head -500` 이 통과했다.
    # 자른 것을 말하는 낱말이 그 줄에 있어야 한다. **`!!` 를 키로 쓰면 안 된다** — 그건
    # 명령이 실패했다는 표시지 잘랐다는 표시가 아니고, 실제로 `!!` 를 가진 줄에 `head -500`
    # 을 넣으니 통과했다. 자르기를 말하는 낱말만 본다.
    # `...` 은 키로 못 쓴다 — `git diff main...HEAD` 가 그것을 갖고 있어 면제돼버린다.
    CUT_WORDS = ('뿐이다', '앞 ', '생략', '만 보여준다', '전체 요구 ID')
    for line in inj:
        for m in re.finditer(r'\b(?:head|tail) -\d+', line):
            if any(w in line for w in CUT_WORDS):
                continue
            print(f"  ✗ {f}: 말없이 자른다 — {m.group(0)}"); fail = 1; bad = 1
            break
    if not bad:
        print(f"  ✓ {f.split('/')[-2] if 'skills' in f else f.split('/')[-1]}: 내는 문자열 {len(emitted)}개 전부 설명됨")
sys.exit(fail)
PY
