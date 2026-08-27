#!/usr/bin/env bash
# PreToolUse(Bash): 스킬이 있는 작업을 손으로 치면 막고 스킬을 알려준다.
#
# 왜 훅인가 — "스킬을 써라" 는 `CLAUDE.md` 에 적어봐야 사람도 에이전트도 안 지킨다.
# 실제로 안 지켜졌다: 킷 PR 넷을 `gh pr create --fill` 로 열어서, open-pr 이 요구하는
# 네 절도 게이트 출력 증거도 "자동화가 닿지 않은 것" 도 빠진 채 나갔다.
# 킷 자신의 규칙이 그것을 예고한다 — `리뷰`·`사람` 만 적힌 규칙은 안 지켜진다.
#
# `git commit` 은 막지 않는다. 빈도가 높아 막으면 우회 습관이 생긴다.
set -uo pipefail
cmd=$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("tool_input") or {}).get("command",""))' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

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

case "$cmd" in
  *"gh pr create"*)
    deny "이 레포는 PR 을 open-pr 스킬로 연다. 그 스킬이 게이트를 돌려 그 출력을 본문의 증거로 붙이고, '자동화가 닿지 않은 것' 을 비워두지 못하게 한다. gh 로 직접 열면 그 절들이 통째로 빠진다. Skill 도구로 open-pr 을 호출하라." ;;
  *"gh pr merge"*)
    deny "이 레포는 머지를 merge-pr 스킬로 한다. 그 스킬이 CI·리뷰·브랜치 보호 상태를 먼저 확인한다. Skill 도구로 merge-pr 을 호출하라." ;;
esac
exit 0
