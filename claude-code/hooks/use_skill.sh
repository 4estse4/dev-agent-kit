#!/usr/bin/env bash
# PreToolUse(Bash): 스킬이 있는 작업을 손으로 치면 막고 스킬을 알려준다.
#
# 왜 훅인가 — "스킬을 써라" 는 `CLAUDE.md` 에 적어봐야 사람도 에이전트도 안 지킨다.
# 실제로 안 지켜졌다: 킷 PR 넷을 `gh pr create --fill` 로 열어서, open-pr 이 요구하는
# 네 절도 게이트 출력 증거도 "자동화가 닿지 않은 것" 도 빠진 채 나갔다.
# 킷 자신의 규칙이 그것을 예고한다 — `리뷰`·`사람` 만 적힌 규칙은 안 지켜진다.
#
# `git commit` 은 막지 않는다. 빈도가 높아 막으면 우회 습관이 생긴다.
#
# 이 훅이 막는 것과 못 막는 것을 분명히 해둔다:
#   막는다   — 스킬 밖에서 `gh pr create` · `gh pr merge` 를 직접 치는 것
#             `gh issue create` 의 **첫 시도** — 사람에게 보여주고 허락받게 돌려세운다
#   못 막는다 — 스킬 **안에서** 사람 허락 없이 머지하는 것. 실제로 그렇게 머지된 적이 있다.
#             그것을 막는 층은 merge-pr 의 절차뿐이고, 절차는 지켜진다고 가정하지 않는다.
#             이슈에서 허락을 **받았는지** 판별하는 것. 훅은 접두어 유무만 본다.
#             pr create·merge 는 스킬 파일이 접두어를 붙이지만 이슈에는 그런 스킬이 없어
#             접두어를 붙이는 주체가 에이전트 자신이다. 그래서 deny 문구는 **접두어를
#             알려주지 않는다** — 알려주면 이 층이 막는 것은 왕복 한 번이 전부가 된다.
#             그리고 이 자리에서는 이 훅이 **유일한 층**이다. PreToolUse 의 deny 가
#             권한 평가보다 먼저 끝나는 것을 실측했다 — 허용 목록에 없는 명령인데도
#             프롬프트가 뜨지 않고 이 훅의 문구가 바로 돌아왔다. 그래서 같은 명령을
#             settings.json 의 ask 에도 넣으면 그 줄은 죽은 줄이 된다. 넣지 않았다.
#   무관하다  — 사람이 GitHub 웹에서 누르는 머지. 훅은 에이전트의 Bash 호출만 본다.
set -uo pipefail

# python3 가 없으면 이 훅은 아무것도 못 한다. 조용히 통과시키면 강제 계층이
# 사라진 것을 아무도 모른다 — stderr 로 말하고 통과한다(차단은 못 하므로).
command -v python3 >/dev/null 2>&1 || {
  echo "use_skill 훅: python3 이 없어 검사하지 못했습니다" >&2; exit 0; }

cmd=$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("tool_input") or {}).get("command",""))' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# ── 어디를 보는가 ──
# 명령 문자열에 그 글자가 **들어 있기만** 해도 막으면 오탐이 쏟아진다. 실제로 그랬다:
#   grep -rn "gh pr merge" .claude          ← 스킬 문서를 읽으려던 것뿐인데 막혔다
#   cat > review.md <<EOF … gh pr merge …   ← 리뷰 본문에 명령을 인용했을 뿐인데 막혔다
# 게다가 그때 돌려주는 문구가 "merge-pr 을 호출하라" 라서, 지시를 따르는 에이전트일수록
# grep 하려다 머지 스킬을 부른다 — 훅이 의도와 정반대로 민다.
# 같은 오탐을 이 레포는 이미 겪어 settings.json 의 $comment 에 적어뒀다.
#
# 그래서 **명령의 머리**만 본다. 명령을 조각으로 나누고, 각 조각에서 앞의 환경변수
# 대입을 걷어낸 뒤 그 자리에 `gh pr create|merge` 가 오는 경우에만 막는다.
#
# 조각내는 자리는 `;` `&&` `||` `|` 와 **줄바꿈**이다. 줄바꿈이 빠지면 두 줄짜리 명령의
# 둘째 줄이 검사되지 않는다 — open-pr 이 push 를 1단계, PR 열기를 2단계로 적어두므로
# 두 줄로 이어 치는 것이 바로 이 훅이 근거로 든 사고 형태다.
#
# 조각내기는 **따옴표와 heredoc 상태를 따라간다.** 그 둘을 안 보면 양쪽으로 샌다:
#   - 따옴표를 안 보면 명령을 **글로 인용**한 것이 막힌다. 이 레포의 리뷰·문서가 이
#     명령들을 계속 인용하므로 드문 일이 아니다 — 3차 리뷰의 훅 검증 스크립트가 실제로
#     그것으로 막혔다(따옴표 안이지만 둘째 물리 줄이 `gh pr create` 로 시작했다).
#   - heredoc 을 안 보면 본문 줄이 명령 머리로 보인다. 그렇다고 heredoc 이 있을 때
#     줄바꿈 분리를 통째로 끄면 반대쪽으로 샌다 —
#     `cat > body.md <<'EOF' … EOF ⏎ gh pr create --body-file` 이 그대로 통과한다.
#     본문을 가진 PR 을 손으로 여는 자연스러운 형태에는 언제나 heredoc 이 있다.
# 그래서 따옴표 **밖**에서만 자르고, heredoc 본문은 종료 태그 줄까지 데이터로 보고 버린다.
#
# **남는 구멍 넷. 전부 실측했고, 안 고치기로 정했다.**
#
#   # don't do this  ⏎ gh pr merge 3           → 통과  미탐. `#` 주석을 모르고, 그
#                                                      주석 속 홑따옴표가 따옴표를 연다
#   echo hi & gh pr merge 3                    → 통과  미탐. `&` 를 구분자로 안 본다
#   cat > f <<'EOF-1' ⏎ gh pr merge 3 ⏎ EOF-1  → deny  오탐. 하이픈 든 heredoc 태그
#   cat > f <<\EOF   ⏎ … ⏎ EOF                 → deny  오탐. 백슬래시 이스케이프 태그
#
# 고칠 때마다 새 변종이 나왔다 — 1차 리뷰의 오탐 → 2·3차의 줄바꿈 미탐 → 지금 이 넷.
# 정규식으로 셸을 파싱하는 접근의 한계이고, 더 쫓으면 셸 파서를 만들게 된다.
# **이 넷은 백로그가 아니라 안 하기로 정한 것이다 — 이슈로 열지 마라.**
# 같은 판단이 `docs/dev-log.md` 의 `이관` 칸에 한 줄 있다.
# 아래 `gh issue create` 차단에도 이 넷이 그대로 적용된다 — 조각내기가 같은 코드다.
#
# **이것은 셸 파서가 아니다.** 따옴표와 heredoc 경계만 따라갈 뿐 확장·치환·서브셸은
# 보지 않는다. `env gh pr merge` · `bash -c "…"` · `$(…)` 는 **의도적으로 통과한다** —
# 이 층은 실수 방지용이지 적대적 우회 방지용이 아니다. 그것까지 막으려고 파서를 넣으면
# 1차 리뷰에서 겪은 오탐 지옥으로 돌아간다.
#
# **스킬 자신이 이 명령들을 실행하므로**(open-pr · merge-pr) 그 조각의 환경변수 대입에
# AI_KIT_SKILL=1 이 있으면 통과시킨다. 조각 단위라 `echo AI_KIT_SKILL=1 ; gh pr merge`
# 는 통과하지 않는다.
what=$(printf '%s' "$cmd" | python3 -c '
import re, sys

cmd = sys.stdin.read()

segs, buf = [], []
pending = []          # 이 줄이 끝나면 본문이 시작될 heredoc 들의 종료 태그
quote = ""            # 비어 있으면 따옴표 밖, 아니면 열려 있는 따옴표 문자
i, n = 0, len(cmd)
while i < n:
    c = cmd[i]
    if quote:
        if c == quote:
            quote = ""
        elif c == "\\" and quote == "\x22" and i + 1 < n:
            buf.append(c); i += 1; c = cmd[i]
        buf.append(c); i += 1
        continue
    if c == "\\" and i + 1 < n:        # 줄 이음(\⏎) 포함 — 다음 한 글자는 그대로 넘긴다
        buf.append(c); buf.append(cmd[i + 1]); i += 2
        continue
    if c in "\x27\x22":
        quote = c; buf.append(c); i += 1
        continue
    if cmd.startswith("<<<", i):       # herestring 은 heredoc 이 아니다
        buf.append("<<<"); i += 3
        continue
    m = re.match(r"<<-?\s*([\x27\x22]?)([A-Za-z_][A-Za-z0-9_]*)\1", cmd[i:])
    if m:
        pending.append(m.group(2)); buf.append(m.group(0)); i += m.end()
        continue
    if c == "\n":
        segs.append("".join(buf)); buf = []; i += 1
        while pending:                 # heredoc 본문은 명령이 아니라 데이터다
            tag = pending.pop(0)
            while i < n:
                j = cmd.find("\n", i)
                line = cmd[i:] if j < 0 else cmd[i:j]
                i = n if j < 0 else j + 1
                if line.strip() == tag:
                    break
        continue
    if cmd.startswith("&&", i) or cmd.startswith("||", i):
        segs.append("".join(buf)); buf = []; i += 2
        continue
    if c in "\x3b\x7c":
        segs.append("".join(buf)); buf = []; i += 1
        continue
    buf.append(c); i += 1
segs.append("".join(buf))

for seg in segs:
    seg = seg.strip()
    escaped = False
    while True:
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=(\S*)\s+", seg)
        if not m:
            break
        if m.group(1) == "AI_KIT_SKILL" and m.group(2) == "1":
            escaped = True
        seg = seg[m.end():]
    m = re.match(r"gh\s+(pr\s+(create|merge)|issue\s+create)\b", seg)
    if not m:
        continue
    what = "issue" if m.group(2) is None else m.group(2)
    # 접두어는 **스킬이 자기 명령을 돌린다** 는 표시다. open-pr 은 gh pr create 를,
    # merge-pr 은 gh pr merge 를 돌리므로 그 둘에만 뜻이 있다.
    # gh issue create 를 돌리는 스킬은 없다 — 거기에도 접두어를 먹이면, 스킬 파일에
    # 평문으로 적힌 그 접두어를 읽은 에이전트에게 이슈 등록을 막는 층이 0 이 된다.
    if escaped and what != "issue":
        continue
    print(what)
    break
' 2>/dev/null) || exit 0

[ -n "$what" ] || exit 0

deny() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"hookSpecificOutput": {
  "hookEventName": "PreToolUse",
  "permissionDecision": "deny",
  "permissionDecisionReason": sys.argv[1],
}}))
PY
  exit 0
}

case "$what" in
  create)
    deny "이 레포는 PR 을 open-pr 스킬로 연다. 그 스킬이 게이트를 돌려 그 출력을 본문의 증거로 붙이고, '자동화가 닿지 않은 것' 을 비워두지 못하게 한다. gh 로 직접 열면 그 절들이 통째로 빠진다. Skill 도구로 open-pr 을 호출하라." ;;
  merge)
    deny "이 레포는 머지를 merge-pr 스킬로 한다. 그 스킬이 CI·두 리뷰의 Verdict·재리뷰 여부를 확인하고 **사람에게 허락을 받은 뒤에만** 머지한다. Skill 도구로 merge-pr 을 호출하라." ;;
  issue)
    deny "이 레포에서 이슈 등록은 사람 허락을 받고 한다. 평가자가 보는 레포다. 열려는 이슈의 제목과 본문을 먼저 사람에게 보여주고 허락을 받아라. 허락 없이 다시 시도하지 마라." ;;
esac
exit 0
