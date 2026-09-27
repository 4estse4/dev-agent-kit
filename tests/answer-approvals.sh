#!/usr/bin/env bash
# 레포에 봇 설정(`.claude/bot.json`)이 있으면 3.5 코멘트는 사람의 👍 가 있어야 원본으로 인정되는가.
#
# 두 쪽으로 부른다. (사람) 인용을 확인하는 훅(`claude-code/hooks/round_comment_quotes.sh`)에는
# Claude Code 가 부르는 모양대로 표준입력에 도구 호출 JSON 을 넣고, `merge-pr` 2절이 부르는 판정
# 스크립트(`claude-code/hooks/answer_approvals.sh`)는 스킬에 적힌 모양대로 부른다. 판정 함수만
# 부르면 훅이 판정을 안 쓰는 결함이 초록으로 지나간다.
#
# **네트워크를 안 쓴다.** PATH 앞에 둔 가짜 `gh` 가 경우마다 만든 JSON 에서 PR 코멘트 · 👍 · 레포
# 권한을 돌려주고, 받은 인자와 `GH_REPO` 를 적어 둔다.
#
# 승인으로 인정하는 것: `+1` 리액션이고, 단 계정이 사람 계정이고(봇이면 GraphQL 이 계정을 주지
# 않거나 레포 권한이 없다), 그 계정의 레포 권한이 write 이상이고, 코멘트를 마지막으로 고친 뒤에
# 달았다. 경우마다 이 가운데 하나만 어긋나게 둔다 — 여럿이 어긋나면 이름이 말하는 경로를
# 고정하지 못한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/round_comment_quotes.sh"
SCRIPT="$KIT/claude-code/hooks/answer_approvals.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/bot/.claude" "$T/plain"
git -C "$T/bot" init -q
git -C "$T/plain" init -q
printf '{"app_id": 1, "app": "kit-bot"}\n' > "$T/bot/.claude/bot.json"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, re, sys
a = sys.argv[1:]
joined = ' '.join(a)
with open(os.environ['STUB_GH_ARGS'], 'a') as fh:
    fh.write('GH_REPO=%s %s\n' % (os.environ.get('GH_REPO', ''), joined))
fail = os.environ.get('STUB_FAIL', '')
if fail and fail in joined:
    sys.stderr.write('HTTP 502: Bad Gateway\n')
    sys.exit(1)
d = json.load(open(os.environ['STUB_DATA'], encoding='utf-8'))
if a[:2] == ['pr', 'view']:
    print(json.dumps([c['body'] for c in d['comments']], ensure_ascii=False))
    sys.exit(0)
if a[:2] == ['api', 'graphql']:
    def node(c):
        plus = c.get('plus', [])
        return {'url': c['url'], 'body': c['body'], 'lastEditedAt': c.get('edited'),
                'reactions': {'totalCount': len(plus), 'nodes': [
                    {'createdAt': t, 'user': ({'login': u} if u else None)} for u, t in plus]}}
    nodes = [node(c) for c in d['comments']]
    cut = d.get('split', len(nodes))
    pages = [{'data': {'repository': {'pullRequest': {'comments': {
        'pageInfo': {'hasNextPage': i == 0 and cut < len(nodes), 'endCursor': 'c%d' % i},
        'nodes': part}}}}} for i, part in enumerate([nodes[:cut], nodes[cut:]]) if part or i == 0]
    print(json.dumps(pages if '--slurp' in a else pages[0], ensure_ascii=False))
    sys.exit(0)
m = re.search(r'collaborators/([^/ ]+)/permission', joined)
if a[:1] == ['api'] and m:
    if m.group(1) not in d['perm']:
        sys.stderr.write('gh: Not Found (HTTP 404)\n')
        sys.exit(1)
    print(json.dumps({'permission': d['perm'][m.group(1)]}))
    sys.exit(0)
sys.stderr.write('stub gh: 모르는 호출: %s\n' % joined)
sys.exit(1)
EOF
chmod +x "$T/bin/gh"
fail=0

A1='### 1라운드 코멘트를 읽고 사람이 정한 것

- (사람) "고치고 2라운드"
  → 고친다
'
A2='### 2라운드 코멘트를 읽고 사람이 정한 것

- (사람) "이대로 머지한다"
  → 머지한다
'
U1='https://github.com/o/r/pull/89#issuecomment-1'
U2='https://github.com/o/r/pull/89#issuecomment-2'
PERM='{"4estse4": "admin", "writer": "write", "reader": "read"}'

# data <이름> <코멘트 JSON 목록> [권한 JSON] [나눌 자리] — 가짜 gh 가 읽을 파일을 만든다
data() {
  python3 - "$T/$1.json" "$2" "${3:-$PERM}" "${4:-}" <<'PY'
import json, sys
out, comments, perm, split = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4]
d = {'comments': comments, 'perm': perm}
if split:
    d['split'] = int(split)
json.dump(d, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
PY
}
# c <url> <본문> [고친 시각] [👍 목록 JSON: [[계정|null, 시각], …]] — 코멘트 하나의 JSON
c() {
  python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1], "body": sys.argv[2],
    "edited": sys.argv[3] or None, "plus": json.loads(sys.argv[4])}, ensure_ascii=False))' \
    "$1" "$2" "${3:-}" "${4:-[]}"
}

round_body() {
  printf '## 리뷰 %s라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n- **해결** (사람) "%s"\n  → 고쳤다\n' "$1" "$2"
}
round_body 2 '고치고 2라운드' > "$T/round2.md"
round_body 3 '이대로 머지한다' > "$T/round3.md"
round_body 3 '고치고 2라운드' > "$T/round3-old.md"

# hook <이름> <pass|deny|ask> <데이터> <본문 파일> [사유에 들어 있어야 할 글자] [cwd] [실패시킬 호출]
hook() {
  local name=$1 want=$2 dat=$3 file=$4 must=${5:-} dir=${6:-$T/bot} failon=${7:-} input out got
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
    "tool_input": {"command": sys.argv[2]}}))' "$dir" "gh pr comment 89 --body-file $T/$file")
  : > "$T/gh-args"
  out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_DATA="$T/$dat.json" STUB_GH_ARGS="$T/gh-args" \
    STUB_FAIL="$failon" bash "$HOOK")
  case "$out" in
    *'"permissionDecision": "deny"'*) got=deny ;;
    *'"permissionDecision": "ask"'*) got=ask ;;
    '') got=pass ;;
    *) got="?:$out" ;;
  esac
  if [ "$got" != "$want" ]; then
    echo "  ✗ 훅: ${name} — 기대 ${want}, 실제 ${got}"; fail=1; return
  fi
  if [ -n "$must" ] && ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ 훅: ${name} — 사유에 「${must}」가 없다: ${out}"; fail=1; return
  fi
  echo "  ✓ 훅: ${name} (${got})"
}

# script <이름> <기대 종료 코드> <데이터> <출력에 들어 있어야 할 글자> [cwd] [인자…]
# `merge-pr` 2절이 부르는 모양: `bash .claude/hooks/answer_approvals.sh <N>`
script() {
  local name=$1 want=$2 dat=$3 must=$4 dir=${5:-$T/bot} out rc
  shift 5 2>/dev/null || shift $#
  : > "$T/gh-args"
  out=$(cd "$dir" && PATH="$T/bin:$PATH" STUB_DATA="$T/$dat.json" STUB_GH_ARGS="$T/gh-args" \
    STUB_FAIL="${STUB_FAIL_ON:-}" bash "$SCRIPT" "${@:-89}" 2>&1)
  rc=$?
  if [ "$rc" != "$want" ]; then
    echo "  ✗ 스크립트: ${name} — 기대 종료 ${want}, 실제 ${rc}: ${out}"; fail=1; return
  fi
  if ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ 스크립트: ${name} — 출력에 「${must}」가 없다: ${out}"; fail=1; return
  fi
  echo "  ✓ 스크립트: ${name} (종료 ${rc})"
}

OK='[["4estse4", "2026-09-27T05:00:00Z"]]'
data approved "[$(c "$U1" "$A1" '' "$OK")]"
data none "[$(c "$U1" "$A1")]"
data nouser "[$(c "$U1" "$A1" '' '[[null, "2026-09-27T05:00:00Z"]]')]"
data botlogin "[$(c "$U1" "$A1" '' '[["kit-bot", "2026-09-27T05:00:00Z"]]')]"
data reader "[$(c "$U1" "$A1" '' '[["reader", "2026-09-27T05:00:00Z"]]')]"
data writer "[$(c "$U1" "$A1" '' '[["writer", "2026-09-27T05:00:00Z"]]')]"
data edited-after "[$(c "$U1" "$A1" '2026-09-27T05:10:00Z' "$OK")]"
data edited-before "[$(c "$U1" "$A1" '2026-09-27T04:50:00Z' "$OK")]"
data mixed "[$(c "$U1" "$A1" '' '[[null, "2026-09-27T04:00:00Z"], ["reader", "2026-09-27T04:30:00Z"], ["4estse4", "2026-09-27T05:00:00Z"]]')]"
data two "[$(c "$U1" "$A1"), $(c "$U2" "$A2" '' "$OK")]"
data paged "[$(c "$U1" "$A1" '' "$OK"), $(c "$U2" "$A2" '' "$OK")]" "$PERM" 1

echo "── 봇 설정이 있을 때 — (사람) 인용을 확인하는 훅"
hook "👍 가 있는 3.5 코멘트의 인용" pass approved round2.md
hook "👍 가 없는 3.5 코멘트의 인용" deny none round2.md "$U1"
hook "👍 가 없다는 사유" deny none round2.md "👍 가 없다"
hook "계정을 주지 않는 👍(봇)" deny nouser round2.md "계정을 알 수 없는"
hook "레포 권한이 없는 계정의 👍(봇 이름)" deny botlogin round2.md "$U1"
hook "읽기 권한만 있는 계정의 👍" deny reader round2.md "reader"
hook "write 권한 계정의 👍" pass writer round2.md
hook "👍 뒤에 코멘트를 고침" deny edited-after round2.md "고치기 전에"
hook "코멘트를 고친 뒤에 단 👍" pass edited-before round2.md
hook "인정되지 않는 👍 뒤에 인정되는 👍" pass mixed round2.md
hook "👍 가 있는 쪽의 인용만 씀" pass two round3.md
hook "👍 가 없는 쪽의 인용" deny two round3-old.md "$U1"
hook "둘째 쪽에 있는 3.5 코멘트" pass paged round3.md
hook "코멘트를 못 읽음" deny approved round2.md "실패" "$T/bot" graphql
hook "권한을 못 읽음" deny approved round2.md "실패" "$T/bot" permission
printf '%s' "$A1" > "$T/answer.md"
hook "3.5 코멘트는 여전히 사람에게 묻는다" ask none answer.md

echo "── 봇 설정이 없을 때 — 지금처럼 글자만 대조한다"
hook "👍 가 없는 3.5 코멘트의 인용" pass none round2.md "" "$T/plain"

echo "── merge-pr 2절이 부르는 판정 스크립트"
script "모두 👍 가 있다" 0 approved "✓ $U1"
script "👍 가 없는 3.5 코멘트" 1 two "✗ $U1"
script "👍 가 없다는 까닭" 1 none "👍 가 없다"
script "봇 설정이 없다" 0 none "봇 설정" "$T/plain"
STUB_FAIL_ON=graphql script "코멘트를 못 읽음" 2 approved "판정 못 함"
script "-R 로 준 레포를 gh 에 전달한다" 0 approved "✓ $U1" "$T/bot" 89 -R 4estse4/other
if grep -qF 'GH_REPO=4estse4/other api graphql' "$T/gh-args"; then echo "  ✓ 스크립트: -R 을 GH_REPO 로 전달한다"
else echo "  ✗ 스크립트: -R 을 GH_REPO 로 전달하지 않았다: $(cat "$T/gh-args")"; fail=1; fi

[ "$fail" = 0 ] && echo "  ✓ 봇 설정이 있으면 👍 가 있는 3.5 코멘트만 원본으로 인정한다"
exit "$fail"
