#!/usr/bin/env bash
# 라운드 코멘트 인용 대조 훅(`claude-code/hooks/round_comment_quotes.sh`)이 막아야 할 것을 막고
# 통과시킬 것을 통과시키는가.
#
# **훅을 직접 부르는 쪽이 아니라 Claude Code 가 부르는 모양으로 부른다.** 표준입력에 도구 호출
# JSON 을 넣어 훅의 명령 해석부터 지나가게 한다. 대조 함수만 부르면 명령을 잘못 읽는 결함이
# 초록으로 지나간다.
#
# **네트워크를 안 쓴다.** 훅은 `gh pr view` 로 PR 코멘트를 읽는다. 여기서는 PATH 앞에 둔 가짜
# `gh` 가 `tests/fixtures/round-comment-quotes/` 에 저장해 둔 3.5 코멘트를 JSON 목록으로 돌려주고,
# 받은 인자를 적어 둔다. 3.5 코멘트(`answer*.md`)는 올라간 것을 그대로 복사한 것이다. 라운드
# 코멘트(`round*.md`)는 접히지 않은 부분만 복사했고, `pr64/round7.md` 는 거기서 줄을 더 발췌했다.
# 3.5 코멘트의 제목 줄만 지금 제목(`### N라운드 코멘트를 읽고 사람이 정한 것`)으로 바꿨다(이슈 #84).
# 올라갈 때는 옛 제목이었다. 대조하는 인용은 올라간 그대로다.
#
# `pr64` 는 실제로 난 일이다. 7라운드 코멘트가 3.5 코멘트의 `→` 줄(세션의 판단)을 `(사람)`
# 인용으로 옮겼다. 이 훅이 겨누는 원본 형태다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1                      # 상대 경로 경우가 레포 뿌리를 기준으로 한다
HOOK="$KIT/claude-code/hooks/round_comment_quotes.sh"
FX="$KIT/tests/fixtures/round-comment-quotes"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/empty" "$T/odd"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGS"
[ -n "${STUB_GH_FAIL:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
python3 - "$STUB_GH_DIR" <<'PY'
import glob, json, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], 'answer*.md')))
print(json.dumps([open(f, encoding='utf-8').read() for f in files], ensure_ascii=False))
PY
EOF
chmod +x "$T/bin/gh"
fail=0

# check <이름> <pass|deny|ask> <명령> [3.5 코멘트 디렉터리] [사유에 들어 있어야 할 글자]
check() {
  local name=$1 want=$2 cmd=$3 dir=${4:-$FX/pr89} must=${5:-} input out got
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
    "tool_input": {"command": sys.argv[2]}}))' "$T" "$cmd")
  : > "$T/gh-args"
  out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_DIR="$dir" STUB_GH_ARGS="$T/gh-args" bash "$HOOK")
  case "$out" in
    *'"permissionDecision": "deny"'*) got=deny ;;
    *'"permissionDecision": "ask"'*) got=ask ;;
    '') got=pass ;;
    *) got="?:$out" ;;
  esac
  if [ "$got" != "$want" ]; then
    echo "  ✗ ${name} — 기대 ${want}, 실제 ${got}"; fail=1; return
  fi
  if [ -n "$must" ] && ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ ${name} — 사유에 「${must}」가 없다: ${out}"; fail=1; return
  fi
  echo "  ✓ ${name} (${got})"
}

# 가짜 gh 가 받은 인자에 그 글자가 있나. 훅이 PR 번호나 레포를 잘못 전달하면
# 다른 PR 로 대조한다.
args_has() {
  if grep -qF -- "$2" "$T/gh-args"; then echo "  ✓ $1"
  else echo "  ✗ $1 — gh 가 받은 인자: $(cat "$T/gh-args")"; fail=1; fi
}

mk() { printf '%s' "$2" > "$T/$1"; }
r2=$(cat "$FX/pr89/round2.md")
r4=$(cat "$FX/pr89/round4.md")
post() { printf 'gh pr comment %s --body-file %s' "${2:-89}" "$T/$1"; }

# ── 통과해야 하는 것 ──
check "올라간 2라운드 코멘트 그대로" pass "gh pr comment 89 --body-file $FX/pr89/round2.md"
args_has "gh 에 PR 번호를 전달한다" "pr view 89 "
check "레포를 밝힌 호출" pass "gh pr comment 89 -R 4estse4/ai-native-kit --body-file $FX/pr89/round2.md"
args_has "gh 에 레포를 전달한다" "-R 4estse4/ai-native-kit"
check "올라간 4라운드 코멘트 그대로" pass "gh pr comment 89 --body-file $FX/pr89/round4.md"
check "\\ 줄넘김은 한 줄로 잇는다" pass "gh pr comment 89 \\
  --body-file $FX/pr89/round2.md"
mk nobold.md "${r2//\*\*/}"
check "인용 안의 굵게 표시를 뗀 것" pass "$(post nobold.md)"
# 하위 명령이 comment 가 아니거나, 낱말이 comment 가 아니다
check "PR 코멘트를 읽는 명령(comments)" pass "gh pr view 89 --json comments --jq '.comments[].body'"
check "제목에 comment 가 든 gh pr create" pass \
  "gh pr create --title \"feat(review): round comment quote hook\" --body-file $T/body.md"
check "gh 를 뺀 글자로 찾는 명령" pass "grep -n 'pr comment' claude-code/skills/merge-pr/SKILL.md"
check "레포를 붙인 -R=" pass "gh pr comment 89 -R=4estse4/ai-native-kit --body-file $FX/pr89/round2.md"
args_has "붙인 -R= 의 값을 gh 에 전달한다" "-R 4estse4/ai-native-kit"
mk inner.md "$r4
- (사람) \"고치고 한 라운드 더. … 홈 주소를 명령 인자로 쓰는 모양은 비추천 그대로 둔다.\""
check "따옴표 안을 … 로 줄인 진짜 인용" pass "$(post inner.md)"
mk folded.md "$r4

<details>

- (사람) \"접힌 전문 안의 가짜 인용은 대조하지 않는다\"

</details>"
check "접힌 부분(<details>) 안의 인용은 보지 않는다" pass "$(post folded.md)"
mk span.md "$r4
- (콜드) \`- (사람) \"사람이 한 적 없는 말\"\` 같은 예시를 백틱에 든 항목"
check "백틱 안의 (사람) \"…\" 예시" pass "$(post span.md)"
mk paren.md "$r4
- (콜드) 새 이슈는 따로 연다(사람이 연다)"
check "라벨이 아닌 괄호 글 (사람이 …)" pass "$(post paren.md)"
# 사람의 답에 백틱 안의 " 가 홀수 개 든 경우. PR #59 의 3.5 코멘트에 실제로 있었다.
cat > "$T/odd/answer1.md" <<'EOF'
### 1라운드 코멘트를 읽고 사람이 정한 것

- (사람) "고친다. 둘째 줄은 `(사람) "` 를 안 품는다"
  → 고친다
EOF
cat > "$T/oddround.md" <<'EOF'
## 리뷰 2라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***

- **해결** (사람) "고친다. 둘째 줄은 `(사람) "` 를 안 품는다"
  → 고쳤다
EOF
check "사람의 답에 백틱 안의 \" 가 홀수 개" pass "$(post oddround.md)" "$T/odd"
# 사람의 문장 안에 큰따옴표나 `(사람)` 라벨과 같은 글자가 든 인용. `open-pr` 형식 절이 아래 동작에
# 기대어 「그 글자 자리를 `…` 로 바꿔 한 따옴표 안에 쓴다」고 적는다. 훅은 인용을 큰따옴표 짝으로
# 나눠 대조하고 짝과 짝 사이는 대조하지 않는다. 한 따옴표 안에서 `…` 로 줄인 조각은 한 답 안에
# 순서대로 있어야 한다. 경우마다 3.5 코멘트를 따로 두고 그 경우에 필요한 항목만 넣는다 — 다른 항목과
# 맞으면 이름이 말하는 경로를 고정하지 못한다.
# inner <이름> <기대> <3.5 코멘트의 인용, 줄마다 한 항목> <라운드 코멘트의 인용> [사유에 들어 있어야 할 글자]
n_inner=0
inner() {
  local d="$T/inner$((++n_inner))" q
  mkdir -p "$d"
  { printf '### 1라운드 코멘트를 읽고 사람이 정한 것\n\n'
    while IFS= read -r q; do printf -- '- (사람) %s\n  → 고친다\n' "$q"; done <<< "$3"; } > "$d/answer1.md"
  mk "inner$n_inner.md" "$(printf '## 리뷰 2라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n- **해결** (사람) %s\n  → 고쳤다\n' "$4")"
  check "$1" "$2" "$(post "inner$n_inner.md")" "$d" "${5:-}"
}
inner "큰따옴표 자리를 … 로 바꾼 인용" pass '"그건 … 머지로 … 해도 된다"' '"그건 … 머지로 … 해도 된다"'
inner "… 로 바꾼 인용의 가운데를 다른 답의 낱말로 바꿈" deny '"그건 … 머지로 … 하지 마라"
"이건 닫기로 해도 된다"' '"그건 … 닫기로 … 하지 마라"' "없는 조각: \\\"그건 … 닫기로"
# 아래 넷은 형식 절이 그 글자를 바꾸는 이유와 따옴표를 나누지 않는 이유로 적은 동작이다. 훅이 짝 사이를
# 대조하거나, 라벨 글자를 건너뛰거나, 따옴표끼리의 순서를 보게 되면 여기가 빨개지고, 그때 형식 절의
# 이유 문장도 고친다
inner "그대로 두면 짝 사이의 낱말은 대조하지 않는다" pass '"그건 "머지로" 해도 된다"' \
  '"그건 "닫기로" 해도 된다"'
inner "그대로 둔 홀수 큰따옴표" deny '"그건 "머지로 해도 된다"' '"그건 "머지로 해도 된다"' \
  "따옴표로 인용하지 않은"
inner "그대로 둔 (사람) 글자" deny '"그 줄의 (사람) 라벨을 떼라"' '"그 줄의 (사람) 라벨을 떼라"' \
  "따옴표로 인용하지 않은"
inner "따옴표를 여럿으로 나누면 다른 답의 낱말이 섞여도 대조하지 않는다" pass '"그건" … "머지로" … "하지 마라"
"이건 닫기로 해도 된다"' '"그건" … "닫기로" … "하지 마라"'
check "--help" pass "gh pr comment --help"
check "--delete-last(본문 없음)" pass "gh pr comment 89 --delete-last --yes"

# ── 3.5 코멘트는 사람에게 묻는다 ──
mk answer.md "$(cat "$FX/pr89/answer2.md")"
check "3.5 코멘트" ask "$(post answer.md)" "" "사람의 승인을 받고"
check "3.5 코멘트, \\ 줄넘김" ask "gh pr comment 89 \\
  --body-file $T/answer.md"

# ── 막아야 하는 것: 인용 ──
mk onechar.md "${r2/약속을 빼먹는다/약속을 빼먹었다}"
check "인용 한 글자를 바꿈" deny "$(post onechar.md)" "" "약속을 빼먹었다"
mk arrow.md "$r4
- **해결** (사람) \"질문 창에서 고른 답이다. 4라운드 코멘트를 올렸다.\""
check "3.5 코멘트의 → 줄(세션의 글)을 인용" deny "$(post arrow.md)" "" "질문 창에서 고른 답이다"
mk self.md "$r2
- (사람) \"필수 둘을 고치고 결정 필요에 답을 받아 한 라운드 더 도는 것을 권합니다.\""
check "라운드 코멘트 자신에만 있는 말을 인용" deny "$(post self.md)" "" "한 라운드 더 도는 것을"
check "실제로 난 일 — PR #64 7라운드" deny \
  "gh pr comment 64 --body-file $FX/pr64/round7.md" "$FX/pr64" "그 이유를 커밋 메시지에"
check "3.5 코멘트가 아직 없는 PR" deny "gh pr comment 89 --body-file $FX/pr89/round2.md" "$T/empty"
mk since.md "$r4
- (사람, 1라운드부터) \"1라운드부터 이월된 가짜 지시\""
check "(사람, N라운드부터) 표기" deny "$(post since.md)" "" "이월된 가짜 지시"
mk wrapped.md "$r4
- (사람) \"경로는 파일이 있나로 가리지만,
  번호는 가짜로 바꾼 말이다.\""
check "두 줄로 나뉜 인용" deny "$(post wrapped.md)" "" "번호는 가짜로 바꾼 말이다"
mk elided.md "$r4
- (사람) \"레포 이름을 막는다 … 사람이 한 적 없는 말\""
check "… 로 줄인 인용의 뒤 조각" deny "$(post elided.md)" "" "사람이 한 적 없는 말"
mk stitched.md "$r4
- (사람) \"홈 주소를 … 막는다\""
check "서로 다른 인용의 조각을 … 로 이음" deny "$(post stitched.md)" "" "홈 주소를 … 막는다"
mk reordered.md "$r4
- (사람) \"그대로 둔다 … 홈 주소를 명령 인자로 쓰는 모양은\""
check "한 인용의 조각 순서를 바꿈" deny "$(post reordered.md)"
check "\\ 줄넘김으로 입력한 가짜 인용" deny "gh pr comment 89 \\
  --body-file $T/onechar.md" "" "약속을 빼먹었다"

# ── 막아야 하는 것: 인용이 아닌 (사람) ──
mk l1.md "$r4
- (사람) 훅을 지우고 승인 단계를 되살린다"
check "필수의 따옴표 없는 라벨" deny "$(post l1.md)" "" "따옴표로 인용하지 않은"
mk l2.md "$r4
- **해결** (사람) 사람이 한 적 없는 지시를 따랐다"
check "판정 및 근거의 따옴표 없는 라벨" deny "$(post l2.md)" "" "따옴표로 인용하지 않은"
mk l3.md "$r4
- (사람) “굽은 따옴표로 쓴 가짜”"
check "굽은 따옴표" deny "$(post l3.md)" "" "따옴표로 인용하지 않은"
mk l4.md "$r4
- (사람): \"콜론 뒤의 가짜\""
check "라벨 뒤 콜론" deny "$(post l4.md)" "" "따옴표로 인용하지 않은"
mk l5.md "$r4
1. (사람) 번호 목록의 가짜"
check "번호 목록" deny "$(post l5.md)" "" "따옴표로 인용하지 않은"
mk l6.md "$r4
- (사람) \"레포 이름을 막는다
들여쓰지 않은 이어짐의 가짜\""
check "닫히지 않은 따옴표(들여쓰지 않은 이어짐)" deny "$(post l6.md)" "" "닫히지 않았거나"
mk l7.md "$r4
- **(사람)** \"굵게 감싼 라벨의 가짜\""
check "굵게 감싼 라벨" deny "$(post l7.md)" "" "굵게 감싼 라벨의 가짜"
mk l8.md "$r4
- **해결 (사람)** \"판정어와 같이 굵게 감싼 가짜\""
check "판정어와 같이 굵게 감싼 라벨" deny "$(post l8.md)" "" "같이 굵게 감싼 가짜"
mk l9.md "$r4
- 해결 (사람) 굵지 않은 판정어 뒤의 가짜"
check "굵지 않은 판정어 뒤의 라벨" deny "$(post l9.md)" "" "따옴표로 인용하지 않은"
mk l10.md "## 리뷰 5라운드 — 셀프 ***\`Comment\`*** · 콜드 ***\`Comment\`***

<details>
접힌 블록
</details>

- (사람) \"앞쪽 접힌 블록 뒤의 가짜\""
check "앞쪽에 접힌 블록이 있어도 그 뒤를 본다" deny "$(post l10.md)" "" "앞쪽 접힌 블록 뒤의 가짜"
mk l11.md "$r4

사람이 정했다 (사람) 불릿 밖의 가짜"
check "불릿 밖의 (사람)" deny "$(post l11.md)" "" "따옴표로 인용하지 않은"

# ── 막아야 하는 것: 정규형이 아닌 게시 ──
mk msg.txt "fix: something"
check "한 명령에 게시 둘" deny \
  "gh pr comment 89 -F $FX/pr89/round2.md && gh pr comment 89 --body-file=$T/onechar.md" "" "정규형"
check "줄바꿈 뒤의 다른 명령" deny "$(post onechar.md)
git commit -F msg.txt" "" "정규형"
check "게시 줄 끝의 # 주석" deny "$(post onechar.md) # post
git commit -F msg.txt" "" "정규형"
check "here-string(<<<) 뒤 줄" deny "cat <<< \"hi\"
$(post onechar.md)" "" "정규형"
check "따옴표 안의 << 뒤 줄" deny "echo \"use << EOF style\"
$(post onechar.md)" "" "정규형"
mk copy.md "$r2"               # 대조를 통과하는 옛 초안이 그 자리에 있다
check "같은 명령에서 본문 파일을 바꾼 뒤 게시" deny \
  "cp $T/onechar.md $T/copy.md && gh pr comment 89 --body-file $T/copy.md" "" "정규형"
check "bash -c 래퍼" deny "bash -c \"$(post onechar.md)\"" "" "정규형"
check "표준입력 리다이렉트" deny "gh pr comment 89 --body-file - < $FX/pr89/round2.md" "" "정규형"

# ── 막아야 하는 것: 게시일 수 있는데 정규형이 아닌 것 ──
check "짧은 플래그에 붙인 -F<경로>" deny "gh pr comment 89 -F$T/onechar.md" "" "약속을 빼먹었다"
check "붙인 -F=<경로>" deny "gh pr comment 89 -F=$T/onechar.md" "" "약속을 빼먹었다"
check "번호 앞의 -F<경로>" deny "gh pr comment -F$T/onechar.md 89" "" "약속을 빼먹었다"
check "붙인 -F<경로> 의 3.5 코멘트" ask "gh pr comment 89 -F$T/answer.md"
check "붙인 -b<값>" deny "gh pr comment 89 -bx" "" "절대 경로 파일 하나로만"
check "모르는 플래그" deny "gh pr comment 89 -y --body-file $T/onechar.md" "" "모르는 플래그"
check "하위 명령 앞의 -R" deny \
  "gh pr -R 4estse4/ai-native-kit comment 89 --body-file $T/onechar.md" "" "정규형"
check "따옴표로 감싼 comment" deny "gh pr \"comment\" 89 --body-file $T/onechar.md" "" "약속을 빼먹었다"
check "하위 명령과 플래그 사이에 끼운 \$(…)" deny \
  "gh pr comment 89 \$(cp $T/onechar.md $T/copy.md;) --body-file $T/copy.md" "" "정규형"
check "\$((1<<2)) 뒤 줄의 게시" deny "echo \$((1<<2))
$(post onechar.md)" "" "정규형"
check "\\ 로 끝나는 따옴표 heredoc 뒤 줄의 게시" deny "cat <<'EOF'
path C:\\
EOF
$(post onechar.md)" "" "정규형"
check "heredoc 안 줄머리의 게시 명령" deny "git commit -F - <<'EOF'
fix: x
$(post onechar.md)
EOF" "" "정규형"
check "PR 을 URL 로 적음" deny \
  "gh pr comment https://github.com/other/repo/pull/89 --body-file $FX/pr89/round2.md" "" "번호 하나"
check "eval 래퍼" deny "eval \"$(post onechar.md)\"" "" "정규형"
check "gh 와 pr 사이의 플래그" deny \
  "gh --repo 4estse4/ai-native-kit pr comment 89 --body-file $T/onechar.md" "" "정규형"
check "두 번 준 --body-file" deny \
  "gh pr comment 89 --body-file $FX/pr89/round2.md --body-file $T/onechar.md" "" "두 번"
check "편집기로 쓰는 -e" deny "gh pr comment 89 -e" "" "절대 경로 파일 하나로만"
check "웹으로 쓰는 -w" deny "gh pr comment 89 -w" "" "절대 경로 파일 하나로만"

# ── 막아야 하는 것: 명령 글자 어디에든 게시 명령이 보이면 ──
# 앞에 무엇이 오든, 따옴표 · heredoc 안이든 정규형이 아니면 막는다. 「명령 자리」를 목록으로
# 정해 알아보던 동안 목록 밖(`if` · `timeout` · `bash -lc` …)의 게시가 대조 없이 지나갔다.
check "if 조건 자리" deny "if $(post onechar.md); then echo ok; fi" "" "정규형"
check "while 조건 자리" deny "while $(post onechar.md); do break; done" "" "정규형"
check "then 뒤" deny "if true; then $(post onechar.md); fi" "" "정규형"
check "! 뒤" deny "! $(post onechar.md)" "" "정규형"
check "{ } 안" deny "{ $(post onechar.md); }" "" "정규형"
check "timeout 앞붙임" deny "timeout 60 $(post onechar.md)" "" "정규형"
check "timeout 앞붙임의 3.5 코멘트" deny "timeout 60 $(post answer.md)" "" "정규형"
check "변수 대입 앞붙임" deny "GH_REPO=4estse4/ai-native-kit $(post onechar.md)" "" "정규형"
check "env 앞붙임" deny "env X=1 $(post onechar.md)" "" "정규형"
check "nice 앞붙임" deny "nice $(post onechar.md)" "" "정규형"
check "sudo -E 앞붙임" deny "sudo -E $(post onechar.md)" "" "정규형"
check "command -p 앞붙임" deny "command -p $(post onechar.md)" "" "정규형"
check "앞의 리다이렉트" deny "2>/dev/null $(post onechar.md)" "" "정규형"
check "bash -lc 래퍼" deny "bash -lc '$(post onechar.md)'" "" "정규형"
check "sh -ec 래퍼" deny "sh -ec '$(post onechar.md)'" "" "정규형"
check "find -exec" deny \
  "find $T -name onechar.md -exec gh pr comment 89 --body-file {} \\;" "" "정규형"
check "xargs" deny "echo $T/onechar.md | xargs gh pr comment 89 --body-file" "" "정규형"
check "백틱 명령 치환" deny "echo \`$(post onechar.md)\`" "" "정규형"
check "따옴표 안의 게시 명령 글자" deny "echo 'gh pr comment 89 --body-file x' && gh pr view 89" "" "정규형"
check "sed 로 스킬의 게시 줄을 찾는 명령" deny \
  "sed -n '/^머지/,/^    gh pr comment <N> --body-file <파일>/p' claude-code/skills/merge-pr/SKILL.md" "" \
  "\`pr comment\` 로 찾고"
check "커밋 메시지를 \$(cat <<EOF) 로 전달함" deny "git commit -m \"\$(cat <<'EOF'
fix(hooks): block gh pr comment 89 --body-file with fake quotes
EOF
)\"" "" "정규형"
check "heredoc 으로 쓰는 초안" deny "cat > draft.md <<'EOF'
don't run gh pr comment 89 --body-file x here
EOF" "" "Write"

# ── 판정 못 하면 막는다 ──
STUB_GH_FAIL=1 check "gh 가 실패" deny "gh pr comment 89 --body-file $FX/pr89/round2.md" "" "판정 못 한 것은"
check "인라인 본문 \$(cat …)" deny 'gh pr comment 89 --body "$(cat round2.md)"' "" "절대 경로"
# 레포 뿌리에서 실제로 풀리는 상대 경로다. 절대 경로 규칙이 빠지면 읽혀서 통과한다.
check "상대 경로 본문" deny \
  "gh pr comment 89 --body-file tests/fixtures/round-comment-quotes/pr89/round2.md" "" "상대 경로"
check "없는 본문 파일" deny "$(post no-such-file.md)" "" "읽지 못해"
printf '\xff\xfe## \xeb\xa6\xac\xeb\xb7\xb0 x\n' > "$T/latin.md"
check "UTF-8 이 아닌 본문" deny "$(post latin.md)" "" "UTF-8"

rm -rf "$T"
[ "$fail" = 0 ] && echo "  ✓ 라운드 코멘트 인용 대조 훅이 막을 것만 막는다"
exit $fail
