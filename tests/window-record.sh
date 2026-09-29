#!/usr/bin/env bash
# 창 기록 훅(`window_record.sh`)이 사람 계정으로 올릴 결정만, 고른 보기 글자 그대로 기록하는가.
#
# 사람 계정 코멘트는 세션이 쓰지 않는다. 결정 창에서 사람이 고른 보기로 이 훅이 `- <머리말>: <보기>` 줄을 만들어
# 봇 디렉터리(`<git 공통 디렉터리>/ai-kit-bot/windows/<PR>.jsonl`)에 적고, `human_comment.sh <PR>` 이 그 기록만
# 올린다. 그래서 이 훅이 틀리면 사람이 고르지 않은 글이 사람 계정으로 올라가거나, 고른 결정이 빠진다.
#
# 훅을 Claude Code 가 부르는 모양으로 부른다. 표준입력의 `tool_response` 는 세션 기록에 남는 창의 결과
# (`toolUseResult`: `questions` · `answers` · `annotations`, `answers` 는 질문 → 고른 보기)와 같은 모양으로 둔다.
# 훅이 받는 실제 입력도 이 모양이다(백그라운드 세션에서 기록해 확인했다, 2026-09-29).
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

# ask <디렉터리> <questions JSON> <answers JSON> [tool_response 에 더할 JSON] — 훅을 부르고 출력을 $OUT 에 둔다.
# 넷째 인자는 창 결과의 다른 필드다(`annotations` 의 메모 · `afkTimeoutMs` · `followUp`)
ask() {
  OUT=$(python3 -c 'import json, sys
qs, ans = json.loads(sys.argv[2]), json.loads(sys.argv[3])
resp = {"questions": qs, "answers": ans, "annotations": {}}
resp.update(json.loads(sys.argv[4]) if len(sys.argv) > 4 else {})
print(json.dumps({"session_id": "s1", "cwd": sys.argv[1], "hook_event_name": "PostToolUse",
                  "tool_name": "AskUserQuestion", "tool_input": {"questions": qs},
                  "tool_response": resp}, ensure_ascii=False))' \
    "$@" | (cd "$1" && bash "$HOOK") 2>&1)
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

# 여러 보기를 고른 답은 보기 이름을 `, ` 로 이은 글자이고, 직접 쓴 말도 그 뒤에 `, ` 로 붙는다. `, ` 나 `"` 가
# 든 이름은 JSON 문자열로 감싸 온다 — Claude Code 2.1.283 이 답을 잇는 함수(`t.includes(", ")||t.includes('"')`
# 이면 감싼다)와 그 역변환(따옴표 조각을 `JSON.parse` 로 읽는다)에서 확인했다
rm -rf "$W"
QC=$(python3 -c 'import json, sys
print(json.dumps({"header": "고칠 것", "question": "고칠 것을 모두 골라 주세요. " + sys.argv[1], "multiSelect": True,
                  "options": [{"label": l, "description": "d"} for l in ["A, B 를 함께 고친다", "C 를 고친다", "\"머지로\" 표시를 고친다"]]},
                 ensure_ascii=False))' "$MARK")
# pick <보기…> — Claude Code 가 여러 보기 답을 잇는 모양 그대로 answers JSON 을 만든다
pick() {
  python3 -c 'import json, sys
parts = [json.dumps(t, ensure_ascii=False) if ", " in t or "\"" in t else t for t in sys.argv[2:]]
print(json.dumps({"고칠 것을 모두 골라 주세요. " + sys.argv[1]: ", ".join(parts)}, ensure_ascii=False))' "$MARK" "$@"
}
ask "$T/bot" "[$QC]" "$(pick 'A, B 를 함께 고친다' 'C 를 고친다')"
check "따옴표로 감싸 온 보기 이름은 하나의 보기다" "- 고칠 것: A, B 를 함께 고친다 · C 를 고친다" "$(lines 7)"
rm -rf "$W"
ask "$T/bot" "[$QC]" "$(pick 'C 를 고친다' '"머지로" 표시를 고친다')"
check "이름에 큰따옴표가 든 보기도 하나의 보기다" "- 고칠 것: C 를 고친다 · \"머지로\" 표시를 고친다" "$(lines 7)"
rm -rf "$W"
ask "$T/bot" "[$QC]" "$(pick 'C 를 고친다' '나머지는 다음 PR 로')"
check "여러 보기 뒤에 붙은 직접 쓴 말은 표시한다" " [직접 쓴 말: 고칠 것]" "$(lines 7)"
rm -rf "$W"
ask "$T/bot" "[$QC]" "$(pick 'C 를 고친다' '나머지는, 다음 PR 로')"
check "따옴표로 감싸 온 직접 쓴 말도 표시한다" " [직접 쓴 말: 고칠 것]" "$(lines 7)"

# 사람이 고른 보기에 단 메모(`annotations[질문].notes`)는 결정의 일부다. 보기만 올리면 사람이 붙인 조건이 빠진다
rm -rf "$W"
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}" \
  "{\"annotations\": {\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": {\"notes\": \"단, 필수 2 는 고치지 말 것\"}}}"
check "보기에 메모를 달았으면 직접 쓴 말로 표시한다" " [직접 쓴 말: 1라운드 코멘트]" "$(lines 7)"

# 창에 보기 대신 쓴 글(`response`)이 있으면 Claude Code 는 모델에 그 글만 준다. 세션은 그 글대로 움직이므로 고른
# 보기를 그대로 올리면 사람이 쓴 조건이 빠진다
rm -rf "$W"
ask "$T/bot" "[$Q1, $Q3]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\", \"끝낼 이슈를 골라 주세요. $MARK\": \"끝내지 않는다\"}" \
  '{"response": "잠깐, 필수 2 는 고치지 말고 먼저 설명해 줘"}'
check "창에 쓴 글이 있으면 표지가 있는 질문을 모두 직접 쓴 말로 표시한다" " [직접 쓴 말: 1라운드 코멘트, 끝낼 이슈]" "$(lines 7)"

# 답을 비운 질문은 직접 쓴 말과 다르다 — 세션이 찾을 글이 없으므로 안내가 그것을 나눠 말한다
rm -rf "$W"
ask "$T/bot" "[$Q1, $Q3]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}"
check "답을 비운 질문은 줄로 적지 않는다" "- 1라운드 코멘트: 제안대로 고치고 2라운드 [직접 쓴 말: 끝낼 이슈]" "$(lines 7)"
case "$OUT" in *'답이 없다'*) echo "  ✓ 답을 비운 질문은 답이 없다고 안내한다" ;;
  *) echo "  ✗ 답을 비운 질문을 답이 없다고 안내하지 않았다: $OUT"; fail=1 ;; esac
case "$OUT" in *'답이 없는 질문은 같은 보기로'*) echo "  ✓ 답을 비운 질문은 같은 보기로 다시 묻게 한다" ;;
  *) echo "  ✗ 답을 비운 질문에 할 일을 적지 않았다: $OUT"; fail=1 ;; esac
# 메모 · 직접 쓴 말 · 창에 쓴 글이 있던 질문은 사람이 붙인 조건을 담을 보기가 필요하다
rm -rf "$W"
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}" \
  "{\"annotations\": {\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": {\"notes\": \"단, 필수 2 는 빼고\"}}}"
case "$OUT" in *'메모 · 창에 쓴 글이 있는 질문은 결정이 담긴'*) echo "  ✓ 메모가 있던 질문은 결정이 담긴 구간이나 요지를 보기로 만들게 한다" ;;
  *) echo "  ✗ 메모가 있던 질문에 할 일을 적지 않았다: $OUT"; fail=1 ;; esac

# 사람이 자리를 비워 저절로 닫힌 창(`afkTimeoutMs`)과 질문을 더 요청하며 닫은 창(`followUp`)은 사람이 제출한 답이
# 아니다 — 게시 동의가 아니므로 기록하지 않는다
rm -rf "$W"
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}" '{"afkTimeoutMs": 600000}'
check "사람 없이 저절로 닫힌 창은 기록하지 않는다" "없음" "$(lines 7)"
case "$OUT" in *'기록하지 않았다'*) echo "  ✓ 기록하지 않은 까닭을 세션에 알린다" ;;
  *) echo "  ✗ 기록하지 않은 까닭을 알리지 않았다: $OUT"; fail=1 ;; esac
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}" '{"followUp": "질문을 더 해 주세요"}'
check "질문을 더 요청하며 닫은 창은 기록하지 않는다" "없음" "$(lines 7)"

# 세션의 cwd 는 Bash 의 cd 를 따라 레포의 하위 디렉터리일 수 있다. 기록은 그래도 레포의 git 디렉터리에 둔다.
# 레포를 $T 에서 두 단계 아래에 두어, cwd 기준 상대 경로를 레포 루트에 붙이는 잘못이 기록을 $T/.git 에 두게 한다
rm -rf "$W"; mkdir -p "$T/x/repo/.claude" "$T/x/repo/sub/deep"; git init -q "$T/x/repo"
cp "$T/bot/.claude/bot.json" "$T/x/repo/.claude/"
ask "$T/x/repo/sub/deep" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}"
check "cwd 가 하위 디렉터리여도 레포의 git 디렉터리에 기록한다" "있음" "$([ -s "$T/x/repo/.git/ai-kit-bot/windows/7.jsonl" ] && echo 있음 || echo 없음)"
check "레포 밖에 git 디렉터리를 만들지 않는다" "없음" "$([ -e "$T/.git" ] && echo 있음 || echo 없음)"
# 막기 훅과 allow 는 레포 루트에서 입력한 게시 명령만 받는다 — 하위 디렉터리면 루트로 옮기라고 안내한다
REPO_ABS=$(cd "$T/x/repo" && pwd -P)
case "$OUT" in *"cd $REPO_ABS"*) echo "  ✓ 하위 디렉터리면 레포 루트로 옮긴 뒤 올리라고 안내한다" ;;
  *) echo "  ✗ 하위 디렉터리에서 레포 루트로 옮기라는 안내가 없다: $OUT"; fail=1 ;; esac
ask "$T/bot" "[$Q1]" "{\"PR #7 1라운드 코멘트를 보고 무엇을 할까요? $MARK\": \"제안대로 고치고 2라운드 (추천)\"}"
case "$OUT" in *'cd '*) echo "  ✗ 레포 루트에서도 옮기라고 안내한다: $OUT"; fail=1 ;;
  *) echo "  ✓ 레포 루트에서는 옮기라는 안내가 없다" ;; esac
# 라운드 도중에 정한 결정은 나중에 올리므로, 그때의 cwd 를 이 훅이 모른다 — 루트에서 올리라고 늘 적는다
case "$OUT" in *'라운드 코멘트를 올린 뒤 레포 루트에서'*) echo "  ✓ 라운드 도중의 결정도 레포 루트에서 올리라고 안내한다" ;;
  *) echo "  ✗ 라운드 도중의 결정을 레포 루트에서 올리라는 안내가 없다: $OUT"; fail=1 ;; esac

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
# 게시는 창에서 고른 것이 동의라서 권한 프롬프트를 두지 않는다 — 설치되는 settings.json 이 그 명령을 허용한다
rule='Bash(bash .claude/hooks/human_comment.sh *)'
if python3 -c 'import json, sys; sys.exit(0 if sys.argv[1] in json.load(open(sys.argv[2]))["permissions"]["allow"] else 1)' \
  "$rule" "$KIT/claude-code/settings.json"; then echo "  ✓ settings.json 이 게시 명령을 허용한다: $rule"
else echo "  ✗ settings.json 의 allow 에 없다: $rule"; fail=1; fi

[ "$fail" = 0 ] && echo "  ✓ 창 기록 훅은 사람이 고른 보기만 사람 계정으로 올릴 결정으로 기록한다"
exit "$fail"
