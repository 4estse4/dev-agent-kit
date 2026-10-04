#!/usr/bin/env bash
# 콜드 리뷰 보고를 훅이 봇 디렉터리에 기록하고, 라운드 코멘트의 콜드 리뷰 전문을 그 기록과 대조하는가.
#
# 이 테스트가 있는 이유: 콜드 리뷰는 에이전트가 보고를 돌려주고 세션이 그 글을 라운드 코멘트로 옮겨 적었다
# (이슈 #102). 리뷰가 실제로 실행됐는지는 그 코멘트의 글 말고 아무것도 보지 않았다(이슈 #41).
#
# **Claude Code 가 부르는 모양으로 부른다.** 표준입력에 훅 입력 JSON 을 넣는다. 모양은 Claude Code 2.1.286 의
# 헤드리스 세션에서 기록한 것이다 — 기본 모드는 보고가 `SubagentStop` 의 `last_assistant_message` 에, auto
# 모드는 `SubagentHandback` 도구의 `tool_input.message` 에 오고 그때 `SubagentStop` 의 그 칸은 빈 글이다.
# 훅은 봇 설정(`.claude/bot.json`)이 있는 임시 레포에서 부른다. 봇 설정이 없는 레포는 따로 본다.
#
# 보는 것:
#   · 두 모드의 보고를 「리뷰한 head:」 별 기록 파일에 한 줄씩 남기고, 같은 실행(agent_id)은 한 번만 남긴다
#   · 에이전트 종류(agent_type)가 cold-reviewer 인 것만 남긴다 — 다른 에이전트가 콜드 리뷰 모양의 글을 돌려줘도
#     남기지 않는다. 빈 보고와 봇 설정이 없는 레포도 남기지 않는다
#   · `**Verdict**:` 줄이 없는 보고는 한 번 막고(auto 는 SubagentHandback 거부, 기본은 SubagentStop block),
#     두 번째에는 막지 않고 남긴다
#   · `cold_review.sh <head>` 가 기록된 보고를 글자 그대로 출력한다
#   · 라운드 코멘트 게시 훅(`round_comment_cold.sh`)이 콜드 리뷰 전문을 같은 head 의 기록과 대조해, 같으면
#     통과시키고 다르거나 · 기록이 없거나 · 전문이 없거나 · head 줄이 없거나 · 봇 설정이 없으면 막는다
#   · 기록 훅을 세션이 직접 실행하는 명령을 `bot_guard.sh` 가 막는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
H="$KIT/claude-code/hooks"
fail=0
T=$(mktemp -d)
mkdir -p "$T/repo/.claude" "$T/plain"
git init -q "$T/repo"; git init -q "$T/plain"
printf '{"app_id": 1, "app": "helper-bot"}\n' > "$T/repo/.claude/bot.json"
REC="$T/repo/.git/kit-bot/reviews"
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333

report() { # $1=head $2=Verdict 줄을 넣을지(1/0)
  printf '## Cold review\n\n리뷰한 head: %s\n\n### 발견\n1. [낮음] `a.sh:1` — 본문 `백틱` 과 "따옴표" 가 든 줄\n' "$1"
  [ "$2" = 1 ] && printf '\n---\n\n**Verdict**: Comment — 시험용 보고다.'
}
# $1=이벤트 $2=agent_id $3=보고 $4=도구 이름(선택) $5=stop_hook_active(선택) $6=cwd(선택) $7=agent_type(선택)
hook_in() {
  DEFAULT_CWD="$T/repo" python3 - "$@" <<'PY'
import json, os, sys
ev, aid, rep, tool, active, cwd, atype = (sys.argv[1:8] + [''] * 7)[:7]
cwd = cwd or os.environ['DEFAULT_CWD']
d = {'session_id': 's', 'cwd': cwd, 'hook_event_name': ev, 'agent_id': aid,
     'agent_type': atype or 'cold-reviewer'}
if ev == 'SubagentStop':
    d.update(stop_hook_active=(active == 'true'), last_assistant_message=rep,
             agent_transcript_path='/x/subagents/agent-%s.jsonl' % aid)
else:
    d.update(tool_name=tool or 'SubagentHandback', tool_input={'message': rep})
print(json.dumps(d, ensure_ascii=False))
PY
}
rec() { printf '%s' "$(hook_in "$@")" | bash "$H/review_record.sh"; }
count() { # $1=head → 그 head 의 기록 줄 수
  [ -f "$REC/$1.jsonl" ] && grep -c '' "$REC/$1.jsonl" || echo 0
}
ok() { echo "  ✓ $1"; }
no() { echo "  ✗ $1"; fail=1; }

# ── 기록 ──
out=$(rec PostToolUse a1 "$(report $H1 1)")
[ -z "$out" ] && [ "$(count $H1)" = 1 ] && ok "auto 모드: SubagentHandback 의 보고를 head 별 파일에 남긴다" \
  || no "auto 모드 기록 — 출력 「${out}」 · 줄 $(count $H1)"
python3 - "$REC/$H1.jsonl" "$(report $H1 1)" <<'PY' && ok "기록의 보고가 글자 그대로이고 agent_id · head · 이벤트가 있다" || no "기록 내용이 다르다"
import json, sys
r = json.loads(open(sys.argv[1], encoding='utf-8').readline())
sys.exit(0 if (r.get('report') == sys.argv[2] and r.get('agent_id') == 'a1'
               and r.get('head') == '1' * 40 and r.get('event') == 'PostToolUse') else 1)
PY
rec SubagentStop a1 "" > /dev/null
[ "$(count $H1)" = 1 ] && ok "auto 모드의 SubagentStop(빈 보고)은 남기지 않는다" || no "빈 보고를 남겼다"
rec SubagentStop a1 "$(report $H1 1)" > /dev/null
[ "$(count $H1)" = 1 ] && ok "같은 실행(agent_id)의 같은 보고는 한 번만 남긴다" || no "같은 실행을 두 번 남겼다"
out=$(rec SubagentStop a2 "$(report $H2 1)")
[ -z "$out" ] && [ "$(count $H2)" = 1 ] && ok "기본 모드: SubagentStop 의 보고를 남긴다" || no "기본 모드 기록 — 출력 「${out}」"
rec SubagentStop a3 "$(report $H3 1)" "" false "" general-purpose > /dev/null
rec PostToolUse a3 "$(report $H3 1)" SubagentHandback "" "" general-purpose > /dev/null
[ "$(count $H3)" = 0 ] && ok "cold-reviewer 가 아닌 에이전트가 돌려준 콜드 리뷰 모양의 글은 남기지 않는다" \
  || no "다른 에이전트의 글을 남겼다 — 줄 $(count $H3)"
H6=6666666666666666666666666666666666666666
rec SubagentStop a7 "리뷰한 head: $H6
머리가 다른 보고
**Verdict**: Approve — 고르는 기준은 에이전트 종류다" > /dev/null
[ "$(count $H6)" = 1 ] && ok "cold-reviewer 의 보고는 첫 줄과 상관없이 남긴다" || no "cold-reviewer 의 보고 — 줄 $(count $H6)"
out=$(printf '%s' "$(hook_in PostToolUse p1 "$(report $H3 1)" SubagentHandback '' "$T/plain")" | bash "$H/review_record.sh")
[ -z "$out" ] && [ ! -e "$T/plain/.git/kit-bot" ] && ok "봇 설정이 없는 레포에는 남기지 않는다" || no "봇 설정이 없는 레포 — 출력 「${out}」"

# ── Verdict 가 없는 보고 ──
out=$(rec PreToolUse a4 "$(report $H3 0)")
case "$out" in *'"permissionDecision": "deny"'*Verdict*) ok "auto 모드: Verdict 없는 보고를 처음에는 거부한다" ;;
  *) no "auto 모드 첫 거부 — 출력 「${out}」" ;; esac
out=$(rec PreToolUse a4 "$(report $H3 0)")
[ -z "$out" ] && ok "같은 실행의 두 번째는 거부하지 않는다" || no "두 번째도 거부했다 — 「${out}」"
rec PostToolUse a4 "$(report $H3 0)" > /dev/null
[ "$(count $H3)" = 1 ] && ok "거부 뒤 다시 보낸 보고를 남긴다" || no "거부 뒤의 보고를 남기지 않았다"
out=$(rec PreToolUse a5 "$(report $H2 1)")
[ -z "$out" ] && [ "$(count $H2)" = 1 ] && ok "Verdict 가 있으면 PreToolUse 는 아무것도 하지 않는다" || no "PreToolUse — 출력 「${out}」 · 줄 $(count $H2)"
out=$(rec SubagentStop a6 "$(report $H3 0)" "" false)
case "$out" in *'"decision": "block"'*Verdict*) ok "기본 모드: Verdict 없는 보고를 처음에는 block 한다" ;;
  *) no "기본 모드 첫 block — 출력 「${out}」" ;; esac
out=$(rec SubagentStop a6 "$(report $H3 0)" "" true)
[ -z "$out" ] && [ "$(count $H3)" = 2 ] && ok "두 번째(stop_hook_active)에는 막지 않고 남긴다" || no "두 번째 — 출력 「${out}」 · 줄 $(count $H3)"

# ── 기록을 내는 스크립트 ──
got=$(cd "$T/repo" && bash "$H/cold_review.sh" $H1; echo "rc=$?")
[ "$got" = "$(report $H1 1)
rc=0" ] && ok "cold_review.sh 가 그 head 의 보고를 글자 그대로 출력한다" || no "cold_review.sh 출력이 다르다: $got"
(cd "$T/repo" && bash "$H/cold_review.sh" 4444444444444444444444444444444444444444 > /dev/null 2>&1); r=$?
[ "$r" = 1 ] && ok "기록이 없는 head 는 rc=1" || no "기록이 없는 head — rc=$r"
(cd "$T/plain" && bash "$H/cold_review.sh" $H1 > /dev/null 2>&1); r=$?
[ "$r" = 2 ] && ok "봇 설정이 없으면 rc=2" || no "봇 설정이 없을 때 — rc=$r"

# ── 라운드 코멘트 게시 훅 ──
round() { # $1=파일 $2=head 줄(빈 글이면 없음) $3=콜드 전문(빈 글이면 블록 없음)
  python3 - "$@" <<'PY'
import sys
path, head, cold = sys.argv[1:4]
s = '## 리뷰 1라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n'
if head:
    s += '리뷰한 head: %s\n\n' % head
s += '### 1라운드 발견\n\n**필수** 없음.\n\n---\n\n<details>\n\n<summary>셀프 리뷰 전문</summary>\n\n## Self review\n\n리뷰한 head: %s\n\n**Verdict**: Approve — 없음.\n\n</details>\n' % (head or '0' * 40)
if cold:
    s += '\n<details>\n\n<summary>콜드 리뷰 전문</summary>\n\n%s\n\n</details>\n' % cold
open(path, 'w', encoding='utf-8').write(s)
PY
}
gate() { # $1=이름 $2=기대(pass/deny) $3=본문 파일 $4=사유에 있어야 할 글자 $5=cwd(선택)
  local out got
  out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
    "tool_input": {"command": sys.argv[2]}}))' "${5:-$T/repo}" "gh pr comment 7 --body-file $3" | bash "$H/round_comment_cold.sh")
  case "$out" in *'"permissionDecision": "deny"'*) got=deny ;; '') got=pass ;; *) got="?:$out" ;; esac
  if [ "$got" != "$2" ]; then no "$1 — 기대 $2, 실제 $got $out"; return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -qF -- "$4"; then no "$1 — 사유에 「$4」가 없다: $out"; return; fi
  ok "$1 ($got)"
}
(cd "$T/repo" && bash "$H/cold_review.sh" $H1 > "$T/cold1.md")
round "$T/r-ok.md" $H1 "$(cat "$T/cold1.md")"
gate "cold_review.sh 의 출력을 넣은 라운드 코멘트" pass "$T/r-ok.md"
round "$T/r-edit.md" $H1 "$(sed 's/시험용/손으로 고친/' "$T/cold1.md")"
gate "콜드 전문을 한 낱말 고친 라운드 코멘트" deny "$T/r-edit.md" "기록과 다르다"
round "$T/r-nocold.md" $H1 ""
gate "콜드 전문이 없는 라운드 코멘트" deny "$T/r-nocold.md" "콜드 리뷰 전문"
round "$T/r-norec.md" 5555555555555555555555555555555555555555 "$(cat "$T/cold1.md")"
gate "기록이 없는 head 의 라운드 코멘트" deny "$T/r-norec.md" "기록이 없다"
round "$T/r-nohead.md" "" "$(cat "$T/cold1.md")"
gate "리뷰한 head 줄이 없는 라운드 코멘트" deny "$T/r-nohead.md" "리뷰한 head"
gate "봇 설정이 없는 레포의 라운드 코멘트" deny "$T/r-ok.md" "봇 설정" "$T/plain"
printf '## 머지 결정\n\n- 라운드 하나.\n' > "$T/decision.md"
gate "라운드 코멘트가 아닌 코멘트" pass "$T/decision.md"
round "$T/r-v0.md" $H3 "$(report $H3 0)"
gate "Verdict 없이 기록된 보고를 넣은 라운드 코멘트" pass "$T/r-v0.md"

# ── 기록 훅을 세션이 직접 실행하면 막는다 ──
out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
  "tool_input": {"command": sys.argv[2]}}))' "$T/repo" "bash .claude/hooks/review_record.sh < $T/fake.json" \
  | HOME="$T" bash "$H/bot_guard.sh")
case "$out" in *'"permissionDecision": "deny"'*review_record*) ok "bot_guard.sh 가 기록 훅의 직접 실행을 막는다" ;;
  *) no "기록 훅의 직접 실행 — 출력 「${out}」" ;; esac
out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
  "tool_input": {"command": sys.argv[2]}}))' "$T/repo" "bash -c 'bash claude-code/hooks/review_record.sh < $T/fake.json'" \
  | HOME="$T" bash "$H/bot_guard.sh")
case "$out" in *'"permissionDecision": "deny"'*review_record*) ok "셸의 -c 인자 안에 둔 직접 실행도 막는다" ;;
  *) no "-c 안의 직접 실행 — 출력 「${out}」" ;; esac

rm -rf "$T"
exit $fail
