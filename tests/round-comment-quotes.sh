#!/usr/bin/env bash
# 라운드 코멘트 인용 대조 훅(`claude-code/hooks/round_comment_quotes.sh`)이 막아야 할 것을 막고
# 통과시킬 것을 통과시키는가.
#
# **훅을 직접 부르는 쪽이 아니라 Claude Code 가 부르는 모양으로 부른다.** 표준입력에 도구 호출
# JSON 을 넣어 훅의 명령 해석부터 지나가게 한다. 대조 함수만 부르면 명령을 잘못 읽는 결함이
# 초록으로 지나간다.
#
# **네트워크를 안 쓴다.** 훅은 `gh pr view` 로 PR 코멘트를 읽는다. 여기서는 PATH 앞에 둔 가짜
# `gh` 가 `tests/fixtures/round-comment-quotes/` 에 떠 둔 3.5 코멘트를 JSON 목록으로 돌려준다.
# 픽스처는 올라간 코멘트를 그대로 뜬 것이다. `pr64/round7.md` 만 원문에서 줄을 발췌했다.
#
# `pr64` 는 실제로 난 일이다. 7라운드 코멘트가 3.5 코멘트의 `→` 줄(세션의 판단)을 `(사람)`
# 인용으로 옮겼다. 이 훅이 겨누는 원본 형태다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/round_comment_quotes.sh"
FX="$KIT/tests/fixtures/round-comment-quotes"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/empty"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_GH_FAIL:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
python3 - "$STUB_GH_DIR" <<'PY'
import glob, json, os, sys
files = sorted(glob.glob(os.path.join(sys.argv[1], 'answer*.md')))
print(json.dumps([open(f, encoding='utf-8').read() for f in files], ensure_ascii=False))
PY
EOF
chmod +x "$T/bin/gh"
fail=0

# check <이름> <pass|deny> <명령> [3.5 코멘트 디렉터리] [실패 사유에 들어 있어야 할 글자]
check() {
  local name=$1 want=$2 cmd=$3 dir=${4:-$FX/pr89} must=${5:-} input out got
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
    "tool_input": {"command": sys.argv[2]}}))' "$T" "$cmd")
  out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_DIR="$dir" bash "$HOOK")
  case "$out" in *'"permissionDecision": "deny"'*) got=deny ;; '') got=pass ;; *) got="?:$out" ;; esac
  if [ "$got" != "$want" ]; then
    echo "  ✗ $name — 기대 $want, 실제 $got"; fail=1; return
  fi
  if [ -n "$must" ] && ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ ${name} — 막았지만 사유에 「${must}」가 없다: ${out}"; fail=1; return
  fi
  echo "  ✓ $name ($got)"
}

# 본문 파일을 만든다. 픽스처를 고쳐 쓴 것이라 무엇을 바꿨는지가 이름에 드러나게 한다.
mk() { printf '%s' "$2" > "$T/$1"; }
r2=$(cat "$FX/pr89/round2.md")
r4=$(cat "$FX/pr89/round4.md")

# ── 통과해야 하는 것 ──
check "올라간 2라운드 코멘트 그대로" pass "gh pr comment 89 --body-file $FX/pr89/round2.md"
check "올라간 4라운드 코멘트 그대로" pass "gh pr comment 89 --body-file $FX/pr89/round4.md"
mk nobold.md "${r2//\*\*/}"
check "인용 안의 굵게 표시를 뗀 것" pass "gh pr comment 89 --body-file nobold.md"
mk answer.md "$(cat "$FX/pr89/answer2.md")
- (사람) \"사람이 한 적 없는 말\""
check "3.5 코멘트는 대조하지 않는다(승인 대상이다)" pass "gh pr comment 89 --body-file answer.md"
check "gh pr comment 가 아닌 명령" pass "echo 'gh pr comment 89 --body-file x' && gh pr view 89"
mk inner.md "$r4
- (사람) \"고치고 한 라운드 더. … 홈 주소를 명령 인자로 쓰는 모양은 비추천 그대로 둔다.\""
check "따옴표 안을 … 로 줄인 진짜 인용" pass "gh pr comment 89 --body-file inner.md"

# ── 막아야 하는 것 ──
mk onechar.md "${r2/약속을 빼먹는다/약속을 빼먹었다}"
check "인용 한 글자를 바꿈" deny "gh pr comment 89 --body-file onechar.md" "" "약속을 빼먹었다"
mk arrow.md "$r4
- **해결** (사람) \"질문 창에서 고른 답이다. 4라운드 코멘트를 올렸다.\""
check "3.5 코멘트의 → 줄(세션의 글)을 인용" deny \
  "gh pr comment 89 --body-file arrow.md" "" "질문 창에서 고른 답이다"
mk self.md "$r2
- (사람) \"필수 둘을 고치고 결정 필요에 답을 받아 한 라운드 더 도는 것을 권합니다.\""
check "라운드 코멘트 자신에만 있는 말을 인용" deny \
  "gh pr comment 89 --body-file self.md" "" "한 라운드 더 도는 것을"
check "실제로 난 일 — PR #64 7라운드" deny \
  "gh pr comment 64 --body-file $FX/pr64/round7.md" "$FX/pr64" "그 이유를 커밋 메시지에"
check "3.5 코멘트가 아직 없는 PR" deny "gh pr comment 89 --body-file $FX/pr89/round2.md" "$T/empty"
mk since.md "$r4
- (사람, 1라운드부터) \"1라운드부터 이월된 가짜 지시\""
check "(사람, N라운드부터) 표기" deny "gh pr comment 89 --body-file since.md" "" "이월된 가짜 지시"
mk wrapped.md "$r4
- (사람) \"경로는 파일이 있나로 가리지만,
  번호는 가짜로 바꾼 말이다.\""
check "두 줄로 넘어간 인용" deny "gh pr comment 89 --body-file wrapped.md" "" "번호는 가짜로 바꾼 말이다"
mk elided.md "$r4
- (사람) \"레포 이름을 막는다 … 사람이 한 적 없는 말\""
check "… 로 줄인 인용의 뒤 조각" deny "gh pr comment 89 --body-file elided.md" "" "사람이 한 적 없는 말"
check "한 명령의 둘째 호출(-F · --body-file= 표기)" deny \
  "gh pr comment 89 -F $FX/pr89/round2.md && gh pr comment 89 --body-file=onechar.md" "" "약속을 빼먹었다"

# ── 판정 못 하면 막는다 ──
STUB_GH_FAIL=1 check "gh 가 실패" deny "gh pr comment 89 --body-file $FX/pr89/round2.md" "" "판정 못 한 것은"
check "인라인 본문 \$(cat …)" deny 'gh pr comment 89 --body "$(cat round2.md)"' "" "--body-file"
check "표준입력 본문" deny "gh pr comment 89 --body-file - < $FX/pr89/round2.md" "" "--body-file"
check "없는 본문 파일" deny "gh pr comment 89 --body-file no-such-file.md" "" "--body-file"

rm -rf "$T"
[ "$fail" = 0 ] && echo "  ✓ 라운드 코멘트 인용 대조 훅이 막을 것만 막는다"
exit $fail
