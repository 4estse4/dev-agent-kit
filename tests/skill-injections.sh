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
# 훑을 것이 없으면 통과가 아니다 — 디렉터리 구조가 바뀌는 날 조용히 초록이 된다.
# **glob 마다 따로 본다.** 합쳐서 보면 한쪽이 통째로 사라져도 다른 쪽 때문에 안 비어
# 그대로 지나간다(실측: skills/ 를 옮겨도 agents/ 하나로 초록이었다).
files = []
for pat in ('claude-code/skills/*/SKILL.md', 'claude-code/agents/*.md'):
    got = sorted(glob.glob(pat))
    if not got:
        print(f"  ✗ {pat} 에 해당하는 파일이 없다 — 경로가 바뀌었나"); sys.exit(1)
    files += got
# **아무것도 안 본 검사는 통과가 아니다.** 이 파일이 겪은 결함은 거의 다 "정규식이 그
# 표기를 몰라서 조용히 0건을 봤다" 였다(`echo '…'` · `printf` · `head -n`). 통과와
# 구분이 안 되므로, **거칠게 세어본 수와 정교하게 뽑은 수가 어긋나면 실패**시킨다.
def crude(line):
    # 인자 없는 `echo` 나 `echo 0` 은 메시지가 아니다 — 따옴표 인자를 가진 것만 센다.
    return len(re.findall(r'''\b(?:echo|printf)\b(?:\s+-[a-zA-Z]+)*\s+["']''', line))
def has_var_msg(line):
    # `_m="!! …"; … echo "$_m"` 처럼 변수에 담으면 뽑는 쪽도 거친 쪽도 같이 눈먼다.
    # 대입에 메시지가 들어 있으면 그 대입 자체를 메시지로 본다.
    out = [a or b for a, b in
           re.findall(r'''\b\w+=(?:"([^"]*)"|'([^']*)')''', line)]
    # jq 표현식·경로 같은 대입까지 메시지로 세면 오탐이다. 이 검사가 겨눈 것은
    # **실패 표시를 변수에 숨기는 것**이므로 `!!` 를 담은 대입만 본다.
    return [v for v in out if '!!' in v]
def crude_cut(line):
    # **명령 자리에 있는 것만 본다.** 그냥 낱말로 찾으면 jq 표현식 안의 `head:` 같은
    # 문자열을 명령으로 오인한다(실측: `contains("리뷰한 head:")` 가 걸렸다).
    return len(re.findall(r'(?:^|[|;&(]\s*)(?:head|tail)\b'
                          r'|(?:^|[|;&(]\s*)sed\s+-n'
                          r'|(?:^|[|;&(]\s*)(?:awk|cut)\b', line))

for f in files:
    s = open(f).read()
    # **주입 줄 인식이 빡빡하면 파일이 통째로 빠지고, 화면에는 `✓ 0개` 가 뜬다.**
    # 실측: 줄 끝에 공백 하나만 붙어도 그 파일의 검사 셋이 다 건너뛰어졌다.
    # 들여쓰기·끝공백을 허용하고, **거칠게 본 수와 어긋나면 실패**시킨다.
    inj = re.findall(r'^\s*!`(.*)`\s*$', s, re.M)
    crude_inj = len(re.findall(r'^\s*!`', s, re.M))
    if crude_inj != len(inj):
        print(f"  ✗ {f}: 주입처럼 보이는 줄 {crude_inj}개 중 {len(inj)}개만 읽었다 — 나머지가 검사 밖이다")
        fail = 1
    if not inj:
        continue
    bad = 0
    body = re.sub(r'^!`.*`$', '', s, flags=re.M)          # 주입 줄 자체는 설명이 아니다
    # **뽑는 자리에 예외를 두지 않는다.** `echo "…"` 만 보던 탓에 `echo '…'` 와
    # `printf "…"` 로 쓴 메시지가 통째로 안 보였다(실측: 셋 다 초록).
    # `printf "%s\\n" "…"` 은 첫 인용문이 서식이라, 명령 하나에서 **인용문을 다 본다.**
    # 첫 것만 보면 진짜 메시지가 통째로 안 보인다(실측: printf 로 쓴 새 메시지가 초록).
    CALL = re.compile(r'\b(?:echo|printf)\b((?:\s+(?:-[a-zA-Z]+|"[^"]*"|\'[^\']*\'|[^\s;|&)]+))*)')
    QUOTED = re.compile(r'"([^"]*)"|\'([^\']*)\'')
    def msgs(line):
        out = []
        for call in CALL.finditer(line):
            for a, b in QUOTED.findall(call.group(1)):
                out.append(a or b)
        return out
    emitted = {e for line in inj for e in msgs(line) + has_var_msg(line)}
    # **한 주입 줄이 내는 것들은 다 적히거나 다 안 적히거나여야 한다.** 그 줄의 갈래를
    # 설명하려고 표를 쓰기 시작했으면 그 줄의 갈래를 다 적어야 한다는 뜻이다. 부분만 적힌
    # 표가 통짜 규칙보다 나쁘다 — 실제로 한 줄이 넷을 내는데 표는 셋만 적고, 남은 하나에
    # 대해 "안 나온다" 는 거짓을 적고 있었다.
    partial = set()
    for line in inj:
        outs = [e.split('$')[0].strip() for e in msgs(line) + has_var_msg(line)]
        outs = [o for o in outs if len(o) >= 6]
        listed = [o for o in outs if o in body]
        if listed and len(listed) < len(set(outs)):
            partial |= {o for o in outs if o not in body}
    for e in sorted(emitted):
        # 자르기 표시(`앞 200줄뿐이다` 류)는 **아래 자르기 검사가 이미 강제한다.**
        # 산문 설명까지 요구하면 같은 것을 두 번 요구하는 것이다. 면제가 아니라
        # 담당이 다른 것이고, 그 담당이 실제로 검사한다는 것이 이 줄의 조건이다.
        if any(w in e for w in ('뿐이다', '생략', '만 보여준다', '전체 요구 ID')):
            continue
        # 치환($VAR · ${VAR})이 든 문자열은 통째로 대조할 수 없다 — 첫 $ 앞까지를 본다
        key = e.split('$')[0].strip()
        # 치환이 맨 앞에 오면 접두가 `!!` 만 남는다. 그것을 짧다고 건너뛰면 **`!!` 면제가
        # 좁아진 형태로 되살아난다**(실측). 그럴 때는 치환을 뺀 나머지 조각으로 본다.
        if len(key) < 6:
            key = re.sub(r'\$\{?\w+\}?', ' ', e).strip()
            key = max(key.split('  '), key=len).strip() if '  ' in key else key
            if len(key) < 6:
                continue
        if key in body:
            continue
        # **예외를 두지 않는다.** 예전에는 파일 맨 위의 통짜 규칙(`!!` 로 시작하면 멈춰라)이
        # 있으면 `!!` 로 시작하는 메시지를 전부 면제했는데, 그러면 그 규칙을 가진 파일에
        # 설명 없는 메시지를 새로 넣어도 안 걸린다 — 그리고 그 결함이 실제로 난 파일들이
        # 하필 그 규칙을 가진 파일들이었다. 예외는 검사를 끄는 스위치다.
        if key in partial:
            print(f"  ✗ {f}: 같은 주입 줄의 다른 갈래는 적어놓고 `{key}…` 만 빠졌다")
        else:
            print(f"  ✗ {f}: 주입이 내는 `{key}…` 를 본문이 설명하지 않는다")
        fail = 1; bad = 1
        continue
        print(f"  ✗ {f}: 주입이 내는 `{key}…` 를 본문이 설명하지 않는다"); fail = 1; bad = 1
    # 자르면 잘랐다고 말해야 한다
    # **자르기마다** 그것을 말하는 문구가 붙어야 한다. 줄에 `!!` 가 하나 있다고 해서 그
    # 줄의 모든 자르기가 면제되면, 이미 `!!` 를 가진 줄(예: PR 전체 diff 를 나르는 슬롯)에
    # 어떤 자르기를 넣어도 안 걸린다 — 실측으로 `| head -500` 이 통과했다.
    # **이 검사의 한계를 먼저 적는다.** 자르기가 다 위험한 것은 아니다(샘플 세 줄을
    # 보여주는 것은 정상) — 어떤 자르기가 위험한지는 기계가 못 가린다. 그래서 이 검사는
    # "자르는 줄에 잘랐다고 말하는 낱말이 있나" 까지만 본다. **한 줄에 자르기가 둘이고
    # 하나만 말해도 통과한다**(실측: `head -200 | tail -50`). 그 자리는 사람이 봐야 한다.
    #
    # 자른 것을 말하는 낱말이 그 줄에 있어야 한다. **`!!` 를 키로 쓰면 안 된다** — 그건
    # 명령이 실패했다는 표시지 잘랐다는 표시가 아니고, 실제로 `!!` 를 가진 줄에 `head -500`
    # 을 넣으니 통과했다. 자르기를 말하는 낱말만 본다.
    # `...` 은 키로 못 쓴다 — `git diff main...HEAD` 가 그것을 갖고 있어 면제돼버린다.
    # 플래그 없는 `head` 는 기본 10줄 — 가장 짧게 자르는 표기가 사각지대였다(실측).
    CUT_RE = (r"(?:^|[|;&(]\s*)(?:head|tail)\b(?:\s+-[nc]?\s*\d+)?"
              r"|\bsed\s+-n\s+'?\d+,\d+p"
              r"|\bawk\s+'[^']*NR\s*[<>]=?\s*\d+"
              r"|\bcut\s+-c\s*\d+")
    CUT_WORDS = ('뿐이다', '앞 ', '생략', '만 보여준다', '전체 요구 ID')
    for line in inj:
        for m in re.finditer(CUT_RE, line):
            if any(w in line for w in CUT_WORDS):
                continue
            print(f"  ✗ {f}: 말없이 자른다 — {m.group(0)}"); fail = 1; bad = 1
            break

    # 사각지대 검사 — 뽑는 쪽이 그 줄을 아예 못 봤나
    for line in inj:
        # **수로 견준다.** 진위값으로 보면 한 줄에 둘이고 하나만 뽑혀도 초록이다(실측).
        if crude(line) > len(msgs(line)):
            print(f"  ✗ {f}: echo/printf {crude(line)}개인데 메시지는 {len(msgs(line))}개만 뽑았다 — {line[:50]}")
            fail = 1; bad = 1
        if crude_cut(line) and not re.search(CUT_RE, line):
            print(f"  ✗ {f}: 자르기가 있는데 자르기 정규식이 못 봤다 — {line[:60]}")
            fail = 1; bad = 1
    if not bad:
        print(f"  ✓ {f.split('/')[-2] if 'skills' in f else f.split('/')[-1]}: 내는 문자열 {len(emitted)}개 전부 설명됨")
sys.exit(fail)
PY
