#!/usr/bin/env bash
# 창 기록 훅(`window_record.sh`)이 사람 계정으로 올릴 결정만, 고른 보기 글자 그대로 기록하는가.
#
# 사람 계정 코멘트는 세션이 쓰지 않는다. 결정 창에서 사람이 고른 보기로 이 훅이 `- <머리말>: <보기>` 줄을 만들어
# 봇 디렉터리(`<git 공통 디렉터리>/ai-kit-bot/windows/<PR>.jsonl`)에 적고, `human_comment.sh <PR>` 이 그 기록만
# 올린다. 그래서 이 훅이 틀리면 사람이 고르지 않은 글이 사람 계정으로 올라가거나, 고른 결정이 빠진다.
#
# 훅을 Claude Code 가 부르는 모양으로 부른다. 표준입력의 `tool_response` 는 세션 기록에 남는 창의 결과
# (`toolUseResult`: `questions` · `answers` · `annotations`, `answers` 는 질문 → 고른 보기)와 같은 모양으로 둔다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/window_record.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bot/.claude" "$T/plain"
git init -q "$T/bot"; git init -q "$T/plain"
printf '{"app_id": 1, "app": "kit-bot"}\n' > "$T/bot/.claude/bot.json"
W="$T/bot/.git/ai-kit-bot/windows"
fail=0
MARK='이 결정은 사람 계정으로 PR #7 에 그대로 올라간다.'

# ask <디렉터리> <questions JSON> <answers JSON> — 훅을 부르고 출력을 $OUT 에 둔다
ask() {
  OUT=$(python3 -c 'import json, sys
qs, ans = json.loads(sys.argv[2]), json.loads(sys.argv[3])
print(json.dumps({"session_id": "s1", "cwd": sys.argv[1], "hook_event_name": "PostToolUse",
                  "tool_name": "AskUserQuestion", "tool_input": {"questions": qs},
                  "tool_response": {"questions": qs, "answers": ans, "annotations": {}}}, ensure_ascii=False))' \
    "$1" "$2" "$3" | (cd "$1" && bash "$HOOK") 2>&1)
}
# q <머리말> <질문> <보기…> — 질문 하나의 JSON
q() {
  python3 -c 'import json, sys
h, qu, *opts = sys.argv[1:]
print(json.dumps({"header": h, "question": qu, "multiSelect": False,
                  "options": [{"label": o, "description": "설명"} for o in opts]}, ensure_ascii=False))' "$@"
}
# lines <PR> — 기록의 줄들(기록마다 한 줄에 JSON 의 lines 를 ` ⏎ ` 로 잇는다)과 직접 쓴 말 표시
lines() {
  [ -f "$W/$1.jsonl" ] || { echo 없음; return; }
  python3 -c 'import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    r = json.loads(l)
    print(" ⏎ ".join(r["lines"]) + (" [직접 쓴 말: %s]" % ", ".join(r["free"]) if r.get("free") else ""))' "$W/$1.jsonl"
}
check() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1 — 기대 「$2」, 실제 「$3」"; fail=1; fi
}

Q1=$(q '1라운드 코멘트' "PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK" '제안대로 고치고 2라운드 (추천)' '고치지 않고 멈춘다')
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}"
check "게시 표지가 있는 창의 결정을 「(추천)」을 떼고 기록한다" "- 1라운드 코멘트: 제안대로 고치고 2라운드" "$(lines 7)"
case "$OUT" in *'human_comment.sh 7'*) echo "  ✓ 올리는 명령을 세션에 알린다" ;;
  *) echo "  ✗ 올리는 명령을 세션에 알리지 않았다: $OUT"; fail=1 ;; esac

Q2=$(q '다음 일' '다음에 무엇을 할까요?' '이슈 #161 을 시작한다' '멈춘다')
ask "$T/bot" "[$Q2]" '{"다음에 무엇을 할까요?": "멈춘다"}'
check "게시 표지가 없는 창은 기록하지 않는다(앞 기록만 남는다)" "- 1라운드 코멘트: 제안대로 고치고 2라운드" "$(lines 7)"

rm -rf "$W"
Q3=$(q '끝낼 이슈' "끝낼 이슈를 골라 주세요. $MARK" '#77 도 이 PR 로 끝낸다 (Recommended)' '끝내지 않는다')
ask "$T/bot" "[$Q1, $Q3, $Q2]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"고치지 않고 멈춘다\", \"끝낼 이슈를 골라 주세요. $MARK\": \"#77 도 이 PR 로 끝낸다 (Recommended)\", \"다음에 무엇을 할까요?\": \"멈춘다\"}"
check "한 창의 여러 질문 가운데 표지가 있는 것만 차례대로 한 기록에 담는다" \
  "- 1라운드 코멘트: 고치지 않고 멈춘다 ⏎ - 끝낼 이슈: #77 도 이 PR 로 끝낸다" "$(lines 7)"

rm -rf "$W"
QM=$(python3 -c 'import json, sys
print(json.dumps({"header": "고칠 것", "question": "고칠 것을 모두 골라 주세요. " + sys.argv[1], "multiSelect": True,
                  "options": [{"label": l, "description": "d"} for l in ["A 를 고친다", "B 를 고친다 (추천)", "C 를 고친다"]]},
                 ensure_ascii=False))' "$MARK")
ask "$T/bot" "[$QM]" "{\"고칠 것을 모두 골라 주세요. $MARK\": \"A 를 고친다, B 를 고친다 (추천)\"}"
check "여러 보기를 고르면 ' · ' 로 잇는다" "- 고칠 것: A 를 고친다 · B 를 고친다" "$(lines 7)"

rm -rf "$W"
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"필수 하나만 고치고 머지하자\"}"
check "보기에 없는 말(직접 쓴 말)은 그대로 적지 않고 표시한다" " [직접 쓴 말: 1라운드 코멘트]" "$(lines 7)"

rm -rf "$W"
ask "$T/plain" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}"
check "봇 설정이 없으면 기록하지 않는다" "없음" "$([ -d "$T/plain/.git/ai-kit-bot/windows" ] && echo 있음 || echo 없음)"

# 세션이 기록을 만들거나 고칠 수 없어야 한다. 셸 명령은 막기 훅이 봇 디렉터리 이름으로 막고, Read · Write ·
# Edit 도구는 설치되는 settings.json 의 deny 가 막는다.
for rule in 'Read(//**/ai-kit-bot/**)' 'Write(//**/ai-kit-bot/**)' 'Edit(//**/ai-kit-bot/**)'; do
  if python3 -c 'import json, sys; sys.exit(0 if sys.argv[1] in json.load(open(sys.argv[2]))["permissions"]["deny"] else 1)' \
    "$rule" "$KIT/claude-code/settings.json"; then echo "  ✓ settings.json 이 막는다: $rule"
  else echo "  ✗ settings.json 의 deny 에 없다: $rule"; fail=1; fi
done

[ "$fail" = 0 ] && echo "  ✓ 창 기록 훅은 사람이 고른 보기만 사람 계정으로 올릴 결정으로 기록한다"
exit "$fail"
