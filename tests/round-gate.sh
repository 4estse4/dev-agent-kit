#!/usr/bin/env bash
# 라운드 게이트(`claude-code/hooks/round_gate.sh`)가 사람이 정하기 전의 다음 라운드 콜드 리뷰를 막는가.
#
# 이 테스트가 있는 이유: 「다음 라운드는 사람이 정한다」를 지키던 것은 `open-pr` 3.6 의 5 셈 하나였다. 세션이 실행해
# 출력을 읽는 명령이라 건너뛰면 막는 것이 없었고, 한 프로젝트에서 라운드가 사람 승인 없이 스무 번 진행됐다(ADR-0006).
# 게이트는 메인 세션이 `cold-reviewer` 를 부르는 순간, 지금 브랜치의 열린 PR 에서 봇의 마지막 라운드 코멘트 뒤에 사람
# 계정 코멘트가 있는지 본다. 기준은 3.6 의 5 와 같다.
#
# 훅을 Claude Code 가 부르는 모양(표준입력 JSON)으로 부른다. `gh` 는 가짜다 — `pr list` 에는 `STUB_PRS` 를,
# `pr view` 에는 `STUB_COMMENTS` 를 담은 JSON 을 낸다. `STUB_GH_FAIL` 이 있으면 실패한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/round_gate.sh"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

T=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_GH_FAIL:-}" ] && { echo "gh: network down" >&2; exit 1; }
case "$1 $2" in
  "pr list") printf '%s\n' "${STUB_PRS:-[]}" ;;
  "pr view") printf '{"comments":%s}\n' "${STUB_COMMENTS:-[]}" ;;
  *) echo "stub gh: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"

mkrepo() { # $1=디렉터리 이름 $2=bot 이면 봇 설정을 둔다
  local r="$T/$1"
  git init -q "$r"; git -C "$r" config user.email t@example.com; git -C "$r" config user.name T
  git -C "$r" commit -q --allow-empty -m init; git -C "$r" switch -q -c feat/x
  [ "${2:-}" = bot ] && { mkdir -p "$r/.claude"; echo '{"app_id": 1}' > "$r/.claude/bot.json"; }
  printf '%s' "$r"; }
R=$(mkrepo bot bot)
P=$(mkrepo plain)

# 코멘트 하나: $1=글쓴이 관계(NONE 은 봇) $2=본문 첫 줄
c() { python3 -I -c 'import json,sys; print(json.dumps({"authorAssociation": sys.argv[1], "body": sys.argv[2]}))' "$1" "$2"; }
list() { local IFS=,; printf '[%s]' "$*"; }
ROUND1=$(c NONE '## 리뷰 1라운드 — 셀프 Approve · 콜드 Comment')
ROUND2=$(c NONE '## 리뷰 2라운드 — 셀프 Approve · 콜드 Comment')
HUMAN=$(c OWNER '- 1라운드 코멘트: 제안대로 고치고 2라운드')
BOTNOTE=$(c NONE '## 머지 결정')
STRANGER=$(c NONE '좋아 보입니다')

# $1=설명 $2=기대(통과|막힘) $3=레포 $4=부르는 에이전트 종류 나머지=환경 변수
run() {
  local what=$1 want=$2 repo=$3 kind=$4 out got
  shift 4
  out=$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Agent","cwd":sys.argv[1],"tool_input":{"subagent_type":sys.argv[2],"description":"review","prompt":"PR 을 리뷰해 달라"}}))' "$repo" "$kind" \
        | (cd "$repo" && env PATH="$T/bin:$PATH" "$@" bash "$HOOK" 2>&1))
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=막힘; else got=통과; fi
  if [ "$got" = "$want" ]; then ok "$what → $got"
  else bad "$what → $got (기대 $want)"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}

PR='[{"number":7}]'
run "열린 PR 이 없다"                               통과 "$R" cold-reviewer STUB_PRS='[]'
run "PR 에 라운드 코멘트가 없다(1라운드)"            통과 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS='[]'
run "마지막 라운드 코멘트 뒤에 사람 계정 코멘트가 있다" 통과 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1" "$HUMAN")"
run "마지막 라운드 코멘트 뒤에 아무것도 없다"         막힘 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1")"
run "그 뒤에 봇의 다른 코멘트뿐이다"                 막힘 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1" "$BOTNOTE")"
run "그 뒤에 쓰기 권한 없는 사람의 코멘트뿐이다"      막힘 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1" "$STRANGER")"
run "사람 계정 코멘트가 앞 라운드 뒤에만 있다"        막힘 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1" "$HUMAN" "$ROUND2")"
# 라운드 코멘트를 사람 계정이 올렸으면 그 뒤의 사람 계정 코멘트를 사람의 결정으로 세지 않는다(3.6 의 5 와 같다)
run "사람 계정이 올린 라운드 코멘트 뒤의 사람 계정 코멘트" 막힘 "$R" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$(c OWNER '## 리뷰 1라운드')" "$HUMAN")"
run "cold-reviewer 가 아닌 에이전트"                 통과 "$R" Explore       STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1")"
# 지시문에 그 글자가 든 다른 에이전트 — 셸의 빠른 판정을 지나 에이전트 종류로 거른다
out=$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Agent","cwd":sys.argv[1],"tool_input":{"subagent_type":"general-purpose","prompt":"cold-reviewer 정의를 읽어라"}}))' "$R" \
      | (cd "$R" && env PATH="$T/bin:$PATH" STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1")" bash "$HOOK" 2>&1))
if ! printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then ok "지시문에 cold-reviewer 글자가 든 다른 에이전트 → 통과"
else bad "지시문에 cold-reviewer 글자가 든 다른 에이전트가 막혔다:"; printf '%s\n' "$out" | sed 's/^/      /'; fi
run "gh 가 실패한다"                                막힘 "$R" cold-reviewer STUB_GH_FAIL=1
run "봇 설정이 없는 레포"                            통과 "$P" cold-reviewer STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1")"

# 막을 때의 사유가 PR 번호와 할 일을 알린다
out=$(python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Agent","cwd":sys.argv[1],"tool_input":{"subagent_type":"cold-reviewer","prompt":"x"}}))' "$R" \
      | (cd "$R" && env PATH="$T/bin:$PATH" STUB_PRS="$PR" STUB_COMMENTS="$(list "$ROUND1")" bash "$HOOK" 2>&1))
if printf '%s' "$out" | grep -q 'PR #7' && printf '%s' "$out" | grep -q 'human_comment.sh 7'; then ok "막는 사유가 PR #7 과 올리는 명령을 적는다"
else bad "막는 사유에 PR 번호나 올리는 명령이 없다:"; printf '%s\n' "$out" | sed 's/^/      /'; fi

# 설치되는 settings 는 설치된 킷의 훅(.claude/hooks/)을, 이 레포의 settings 는 원본(claude-code/hooks/)을 가리킨다
for pair in "claude-code/settings.json:.claude/hooks/round_gate.sh" ".claude/settings.json:claude-code/hooks/round_gate.sh"; do
  s=${pair%%:*} want=${pair#*:}
  if python3 -I - "$KIT/$s" "$want" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))['hooks']
sys.exit(0 if any(m.get('matcher') == 'Agent' and any(sys.argv[2] in x.get('command', '') for x in m['hooks'])
                  for m in h.get('PreToolUse', [])) else 1)
PY
  then ok "${s} 가 ${want} 를 PreToolUse(Agent)에 등록한다"
  else bad "${s} 가 ${want} 를 PreToolUse(Agent)에 등록하지 않는다"; fi
done

exit $fail
