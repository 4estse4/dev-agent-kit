#!/usr/bin/env bash
# 레포에 봇 설정(`.claude/bot.json`)이 있으면 사람의 결정은 사람 계정 코멘트로, 머지 승인은 사람의
# Approve 로 확인하는가.
#
# 세 쪽으로 부른다. (사람) 인용을 확인하는 훅(`claude-code/hooks/round_comment_quotes.sh`)에는
# Claude Code 가 부르는 모양대로 표준입력에 도구 호출 JSON 을 넣는다. `merge-pr` 2절이 부르는 판정
# 스크립트(`claude-code/hooks/human_review.sh approved`)와 사람 계정으로 올리는 스크립트
# (`claude-code/hooks/human_comment.sh`)는 스킬에 적힌 모양대로 부른다. 판정 함수만 부르면 훅이 판정을
# 안 쓰는 결함이 초록으로 통과한다.
#
# **네트워크를 안 쓴다.** PATH 앞에 둔 가짜 `gh` 가 경우마다 만든 JSON 에서 PR 코멘트 · 리뷰 · 레포
# 권한을 돌려주고, 받은 인자와 환경 변수(`GH_REPO` · `GH_CONFIG_DIR` · `GH_TOKEN`)를 적어 둔다.
#
# 경우마다 인정 조건 가운데 하나만 어긋나게 둔다 — 여럿이 어긋나면 이름이 말하는 경로를 고정하지 못한다.
set -u
# 봇에 연결된 세션에서 이 테스트를 실행해도 그 세션의 gh 설정이 섞이지 않게 한다
unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/round_comment_quotes.sh"
REVIEW="$KIT/claude-code/hooks/human_review.sh"
POST="$KIT/claude-code/hooks/human_comment.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/bot/.claude" "$T/plain"
git -C "$T/bot" init -q
git -C "$T/plain" init -q
printf '{"app_id": 1, "app": "helper-bot"}\n' > "$T/bot/.claude/bot.json"

cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, re, sys
a = sys.argv[1:]
joined = ' '.join(a)
with open(os.environ['STUB_GH_ARGS'], 'a') as fh:
    fh.write('GH_REPO=%s GH_CONFIG_DIR=%s GH_TOKEN=%s %s\n' % (
        os.environ.get('GH_REPO', ''), os.environ.get('GH_CONFIG_DIR', ''),
        os.environ.get('GH_TOKEN', ''), joined))
fail = os.environ.get('STUB_FAIL', '')
if fail and fail in joined:
    sys.stderr.write('HTTP 502: Bad Gateway\n')
    sys.exit(1)
d = json.load(open(os.environ['STUB_DATA'], encoding='utf-8'))
if a[:2] == ['pr', 'comment']:
    if os.environ.get('STUB_BODY') and '--body-file' in a:
        open(os.environ['STUB_BODY'], 'w', encoding='utf-8').write(
            open(a[a.index('--body-file') + 1], encoding='utf-8').read())
    print('https://github.com/o/r/pull/89#issuecomment-99')
    sys.exit(0)
if a[:2] == ['pr', 'view'] and 'headRefOid' in joined:
    print(json.dumps({'headRefOid': d['head'], 'reviewDecision': d.get('decision', '')}))
    sys.exit(0)
if a[:2] == ['pr', 'view']:
    print(json.dumps([c['body'] for c in d['comments']], ensure_ascii=False))
    sys.exit(0)
if a[:2] == ['api', 'graphql']:
    def node(c):
        return {'url': c['url'], 'body': c['body'], 'authorAssociation': c['assoc'],
                'author': {'login': c['author']} if c['author'] else None,
                'editor': {'login': c['editor']} if c.get('editor') else None}
    nodes = [node(c) for c in d['comments']]
    cut = d.get('split', len(nodes))
    pages = [{'data': {'repository': {'pullRequest': {'comments': {
        'pageInfo': {'hasNextPage': i == 0 and cut < len(nodes), 'endCursor': 'c%d' % i},
        'nodes': part}}}}} for i, part in enumerate([nodes[:cut], nodes[cut:]]) if part or i == 0]
    print(json.dumps(pages if '--slurp' in a else pages[0], ensure_ascii=False))
    sys.exit(0)
if re.search(r'pulls/\d+/reviews', joined):
    revs = [{'user': {'login': r[0]} if r[0] else None, 'state': r[1], 'commit_id': r[2],
             'submitted_at': r[3]} for r in d['reviews']]
    print(json.dumps([revs] if '--slurp' in a else revs))
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

# 창에서 고른 보기로 만든 사람 계정 코멘트
A1='- 1라운드 코멘트: 고치고 2라운드
'
# 옛 제목 코멘트. 이제 따로 다루지 않는다
OLDANS='### 1라운드 코멘트를 읽고 사람이 정한 것

- (사람) "고치고 2라운드"
  → 고친다
'
# 사람이 PR 웹에서 직접 쓴 코멘트. 제목도 라벨도 없다.
W1='리뷰 봤다. 필수는 고치고 2라운드 진행해. 비추천은 그대로 둬'
U1='https://github.com/o/r/pull/89#issuecomment-1'
U2='https://github.com/o/r/pull/89#issuecomment-2'
PERM='{"4estse4": "admin", "writer": "write", "reader": "read"}'
H='cccccccccccccccccccccccccccccccccccccccc'
OLD='dddddddddddddddddddddddddddddddddddddddd'

# data <이름> <코멘트 JSON 목록> [리뷰 JSON 목록] [나눌 자리] [reviewDecision] — 가짜 gh 가 읽을 파일을 만든다
data() {
  python3 - "$T/$1.json" "$2" "${3:-[]}" "$PERM" "$H" "${4:-}" "${5:-}" <<'PY'
import json, sys
out, comments, reviews, perm, head, split, decision = sys.argv[1:]
d = {'comments': json.loads(comments), 'reviews': json.loads(reviews), 'perm': json.loads(perm), 'head': head,
     'decision': decision}
if split:
    d['split'] = int(split)
json.dump(d, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
PY
}
# c <url> <본문> <글쓴이|''> <authorAssociation> [마지막으로 고친 계정] — 코멘트 하나의 JSON
c() {
  python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1], "body": sys.argv[2],
    "author": sys.argv[3] or None, "assoc": sys.argv[4], "editor": sys.argv[5] or None}, ensure_ascii=False))' \
    "$1" "$2" "$3" "$4" "${5:-}"
}

round_body() {
  printf '## 리뷰 %s라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n- **해결** (사람) "%s"\n  → 고쳤다\n' "$1" "$2"
}
round_body 2 '고치고 2라운드' > "$T/round2.md"
round_body 2 '고치고 3라운드' > "$T/round2-other.md"
round_body 2 '1라운드 코멘트: 고치고 2라운드' > "$T/round2-line.md"
printf '## 리뷰 2라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n- **해결** (셀프) 고쳤다\n' > "$T/round2-noquote.md"
# 사람이 PR 웹에서 Quote reply 로 봇의 글을 인용해 넣고 정한 것을 쓴 코멘트
QR='> 결정 필요는 이 코멘트 뒤 질문 창으로 여쭙니다.

그냥 고치고 한 라운드 더'
round_body 2 '결정 필요는 이 코멘트 뒤 질문 창으로 여쭙니다' > "$T/round2-quoted.md"
round_body 2 '그냥 고치고 한 라운드 더' > "$T/round2-reply.md"

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

# approved <이름> <기대 종료 코드> <데이터> <출력에 들어 있어야 할 글자> [cwd] [인자…]
# `merge-pr` 2절이 부르는 모양: `bash .claude/hooks/human_review.sh approved <N>`
approved() {
  local name=$1 want=$2 dat=$3 must=$4 dir=${5:-$T/bot} out rc
  shift 5 2>/dev/null || shift $#
  : > "$T/gh-args"
  out=$(cd "$dir" && PATH="$T/bin:$PATH" STUB_DATA="$T/$dat.json" STUB_GH_ARGS="$T/gh-args" \
    STUB_FAIL="${STUB_FAIL_ON:-}" bash "$REVIEW" approved "${@:-89}" 2>&1)
  rc=$?
  if [ "$rc" != "$want" ]; then
    echo "  ✗ Approve: ${name} — 기대 종료 ${want}, 실제 ${rc}: ${out}"; fail=1; return
  fi
  if ! printf '%s' "$out" | grep -qF -- "$must"; then
    echo "  ✗ Approve: ${name} — 출력에 「${must}」가 없다: ${out}"; fail=1; return
  fi
  echo "  ✓ Approve: ${name} (종료 ${rc})"
}

# post <이름> <기대 종료 코드> [cwd] [인자…] — 사람 계정으로 올리는 스크립트를 PR 89 로 부른다. 올린 본문은
# $T/body 에 남는다. 세션의 봇 연결(GH_CONFIG_DIR · GH_TOKEN)을 준 채로 부른다 — 스크립트가 그것을 지워야 사람
# 계정이다.
post() {
  local name=$1 want=$2 dir=${3:-$T/bot} out rc
  shift 3 2>/dev/null || shift $#
  : > "$T/gh-args"; rm -f "$T/body"
  out=$(cd "$dir" && PATH="$T/bin:$PATH" STUB_DATA="$T/none.json" STUB_GH_ARGS="$T/gh-args" STUB_BODY="$T/body" \
    GH_CONFIG_DIR="$T/botcfg" GH_TOKEN=ghs_stubtoken bash "$POST" 89 "$@" 2>&1)
  rc=$?
  OUT=$out
  if [ "$rc" != "$want" ]; then
    echo "  ✗ 올리기: ${name} — 기대 종료 ${want}, 실제 ${rc}: ${out}"; fail=1; return
  fi
  echo "  ✓ 올리기: ${name} (종료 ${rc})"
}

OWNER_A1=$(c "$U1" "$A1" 4estse4 OWNER)
data person "[$OWNER_A1]"
data botonly "[$(c "$U1" "$A1" helper-bot NONE)]"
data web "[$(c "$U1" "$W1" 4estse4 OWNER)]"
data quote-reply "[$(c "$U1" "$QR" 4estse4 OWNER)]"
data edited-other "[$(c "$U1" "$A1" 4estse4 OWNER helper-bot)]"
data edited-self "[$(c "$U1" "$A1" 4estse4 OWNER 4estse4)]"
data collab "[$(c "$U1" "$A1" writer COLLABORATOR)]"
data member "[$(c "$U1" "$A1" writer MEMBER)]"
data member-reader "[$(c "$U1" "$A1" reader MEMBER)]"
data contrib "[$(c "$U1" "$A1" someone CONTRIBUTOR)]"
data paged "[$(c "$U2" "## 리뷰 1라운드" helper-bot NONE), $OWNER_A1]" '[]' 1
data none '[]'

echo "── 봇 설정이 있을 때 — (사람) 인용을 확인하는 훅"
hook "사람 계정 코멘트의 인용" pass person round2.md
hook "봇 계정 코멘트에만 있는 인용" deny botonly round2.md "사람 계정"
hook "사람이 PR 웹에서 쓴 코멘트의 한 구절" pass web round2.md
# Quote reply 의 `> …` 줄은 봇이 쓴 글이다
hook "Quote reply 로 인용된 봇의 글" deny quote-reply round2-quoted.md "사람 계정"
hook "Quote reply 뒤에 사람이 정한 것" pass quote-reply round2-reply.md
hook "사람 코멘트에 없는 인용" deny web round2-other.md "고치고 3라운드"
hook "다른 계정이 고친 사람 코멘트" deny edited-other round2.md "고친"
hook "글쓴이가 스스로 고친 코멘트" pass edited-self round2.md
hook "협력자(COLLABORATOR) 코멘트" pass collab round2.md
hook "조직 구성원(MEMBER) 코멘트" pass member round2.md
# MEMBER 는 레포 권한과 상관없이 붙는다. 원본은 쓰기 권한이 있는 사람의 글이다.
hook "읽기 권한만 있는 조직 구성원의 코멘트" deny member-reader round2.md "사람 계정"
hook "원본의 권한을 못 읽음" deny person round2.md "실패" "$T/bot" permission
# 사람 계정 코멘트는 `- 주제: 보기` 줄이다. 줄 전체를 인용해도, 보기 글자만 인용해도 원본에 있다
hook "사람 계정 코멘트의 줄 전체" pass person round2-line.md
hook "쓰기 권한 없는 기여자(CONTRIBUTOR) 코멘트" deny contrib round2.md "사람 계정"
hook "둘째 쪽에 있는 사람 코멘트" pass paged round2.md
hook "코멘트를 못 읽음" deny person round2.md "실패" "$T/bot" graphql
# 옛 제목(`### N라운드 코멘트를 읽고 사람이 정한 것`)의 글은 이제 따로 다루지 않는다 — 봇이 올리면 봇의 글일
# 뿐 원본이 아니다
printf '%s' "$OLDANS" > "$T/answer.md"
hook "옛 제목의 글은 따로 막지 않는다" pass person answer.md
data botold "[$(c "$U1" "$OLDANS" helper-bot NONE)]"
hook "봇이 올린 옛 제목 코멘트의 인용" deny botold round2.md "사람 계정"

echo "── 봇 설정이 없을 때 — (사람) 인용의 원본이 없어 막는다(킷은 봇과 함께 쓴다)"
hook "(사람) 인용이 든 라운드 코멘트" deny person round2.md "봇" "$T/plain"
hook "(사람) 인용이 없는 라운드 코멘트" pass person round2-noquote.md "" "$T/plain"
hook "옛 제목의 글은 묻지 않는다" pass person answer.md "" "$T/plain"

echo "── merge-pr 2절이 부르는 Approve 판정"
data ok '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]"
data old '[]' "[[\"4estse4\", \"APPROVED\", \"$OLD\", \"2026-09-27T05:00:00Z\"]]"
data reader-ok '[]' "[[\"reader\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]"
data bot-ok '[]' "[[\"helper-bot[bot]\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]"
data then-changes '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"], [\"4estse4\", \"CHANGES_REQUESTED\", \"$H\", \"2026-09-27T05:10:00Z\"]]"
data other-changes '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"], [\"writer\", \"CHANGES_REQUESTED\", \"$H\", \"2026-09-27T05:10:00Z\"]]"
data then-comment '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"], [\"4estse4\", \"COMMENTED\", \"$H\", \"2026-09-27T05:10:00Z\"]]"
data dismissed '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"], [\"4estse4\", \"DISMISSED\", \"$H\", \"2026-09-27T05:10:00Z\"]]"
data changes-then-ok '[]' "[[\"4estse4\", \"CHANGES_REQUESTED\", \"$OLD\", \"2026-09-27T04:00:00Z\"], [\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]"
approved "지금 head 에 사람의 Approve" 0 ok "✓ 4estse4"
approved "이전 커밋에 한 Approve" 1 old "이전 커밋"
approved "읽기 권한 계정의 Approve" 1 reader-ok "reader"
approved "봇 계정의 Approve" 1 bot-ok "Approve 가 없다"
approved "Approve 뒤 같은 사람의 Request changes" 1 then-changes "Request changes"
approved "다른 쓰기 권한자의 Request changes" 1 other-changes "writer"
approved "Approve 뒤 같은 사람의 Comment" 0 then-comment "✓ 4estse4"
approved "없던 것이 된(Dismissed) Approve" 1 dismissed "Approve 가 없다"
approved "Request changes 뒤 같은 사람의 Approve" 0 changes-then-ok "✓ 4estse4"
approved "리뷰가 없다" 1 none "Approve 가 없다"
# 브랜치 보호의 필요 승인 수는 GitHub 이 계산한 reviewDecision 으로 본다
data ok-short '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]" '' REVIEW_REQUIRED
data ok-enough '[]' "[[\"4estse4\", \"APPROVED\", \"$H\", \"2026-09-27T05:00:00Z\"]]" '' APPROVED
approved "필요 승인 수가 모자람" 1 ok-short "필요 승인 수"
# 승인한 사람이 마지막으로 푸시했으면 그 Approve 는 세어지지 않는다(마지막 푸시 승인). 조치가 다르다.
approved "필요 승인이 모자랄 때 마지막 푸시도 알린다" 1 ok-short "마지막으로 푸시"
approved "필요 승인 수를 채움" 0 ok-enough "✓ 4estse4"
approved "봇 설정이 없다" 2 ok "봇 설정" "$T/plain"
STUB_FAIL_ON=reviews approved "리뷰를 못 읽음" 2 ok "판정 못 함"
STUB_FAIL_ON=permission approved "권한을 못 읽음" 2 ok "판정 못 함"
approved "-R 로 준 레포를 gh 에 전달한다" 0 ok "✓ 4estse4" "$T/bot" 89 -R 4estse4/other
if grep -qF 'GH_REPO=4estse4/other' "$T/gh-args" && ! grep -q '^GH_REPO= ' "$T/gh-args"; then
  echo "  ✓ Approve: -R 을 모든 gh 호출에 GH_REPO 로 전달한다"
else echo "  ✗ Approve: -R 을 GH_REPO 로 전달하지 않은 호출이 있다: $(cat "$T/gh-args")"; fail=1; fi

echo "── 사람 계정으로 올리는 스크립트 — 창 기록 훅이 적은 기록만 올린다"
WIN="$T/bot/.git/kit-bot/windows"
# rec <줄…> — PR 89 의 기록 하나를 더한다(창 기록 훅이 쓰는 모양). FREE 가 있으면 그 머리말을 직접 쓴 말로 표시한다
rec() {
  mkdir -p "$WIN"
  python3 -c 'import json, os, sys
print(json.dumps({"at": "2026-09-29T00:00:00Z", "session": "s1", "lines": sys.argv[1:],
                  "free": [os.environ["FREE"]] if os.environ.get("FREE") else []}, ensure_ascii=False))' "$@" >> "$WIN/89.jsonl"
}
body_is() {
  if [ "$(cat "$T/body" 2>/dev/null)" = "$2" ]; then echo "  ✓ 올리기: $1"
  else echo "  ✗ 올리기: $1 — 올린 본문: 「$(cat "$T/body" 2>/dev/null)」"; fail=1; fi
}
no_gh() {
  if [ -s "$T/gh-args" ]; then echo "  ✗ 올리기: $1 — gh 를 불렀다: $(cat "$T/gh-args")"; fail=1
  else echo "  ✓ 올리기: $1"; fi
}
post "기록이 없으면 올리지 않는다" 1
no_gh "기록이 없으면 gh 를 부르지 않는다"
rec '- 1라운드 코멘트: 제안대로 고치고 2라운드' '- 끝낼 이슈: #77 도 이 PR 로 끝낸다'
rec '- 2라운드 코멘트: 머지한다'
post "올리지 않은 기록을 올린다" 0
body_is "기록들을 창이 끝난 차례대로 한 코멘트에 모은다" '- 1라운드 코멘트: 제안대로 고치고 2라운드
- 끝낼 이슈: #77 도 이 PR 로 끝낸다
- 2라운드 코멘트: 머지한다'
if grep -q "^GH_REPO= GH_CONFIG_DIR= GH_TOKEN= pr comment 89 --body-file " "$T/gh-args"; then
  echo "  ✓ 올리기: 봇 연결을 지우고 사람의 gh 로 올린다"
else echo "  ✗ 올리기: 봇 연결을 지우지 않았거나 명령이 다르다: $(cat "$T/gh-args")"; fail=1; fi
post "올린 기록은 다시 올리지 않는다" 1
no_gh "올릴 것이 없으면 gh 를 부르지 않는다"
# 기록이 아예 없을 때(창 기록 훅이 실행되지 않았다)와 모두 올렸을 때를 세션이 다르게 다뤄야 한다
case "$OUT" in *'모두 올렸다'*) echo "  ✓ 올리기: 모두 올린 뒤에는 모두 올렸다고 알린다" ;;
  *) echo "  ✗ 올리기: 모두 올린 뒤인데 그렇게 알리지 않았다: $OUT"; fail=1 ;; esac
rec '- 3라운드 코멘트: 고치지 않고 멈춘다'
post "그 뒤에 더한 기록만 올린다" 0
body_is "앞서 올린 기록은 빠진다" '- 3라운드 코멘트: 고치지 않고 멈춘다'
FREE='4라운드 코멘트' rec '- 끝낼 이슈: #78 도 이 PR 로 끝낸다'
post "직접 쓴 말이 든 기록이 있으면 올리지 않는다" 1
no_gh "직접 쓴 말이 있으면 gh 를 부르지 않는다"
case "$OUT" in *'직접 쓴 말'*) echo "  ✓ 올리기: 올리지 않은 까닭을 낸다" ;;
  *) echo "  ✗ 올리기: 까닭이 없다: $OUT"; fail=1 ;; esac
# 직접 쓴 말은 같은 머리말로 다시 띄운 창에서 사람이 고르면 정해진 것이다. 다른 머리말의 창은 그것을 정하지 않는다
rec '- 셀프 발견 1: 고친다'
post "다른 머리말의 창만 뒤에 있으면 여전히 올리지 않는다" 1
no_gh "직접 쓴 말이 정해지지 않았으면 gh 를 부르지 않는다"
rec '- 4라운드 코멘트: 머지한다'
post "같은 머리말의 창에서 고르면 올린다" 0
body_is "직접 쓴 말은 빼고 그 뒤의 기록까지 차례대로 올린다" '- 끝낼 이슈: #78 도 이 PR 로 끝낸다
- 셀프 발견 1: 고친다
- 4라운드 코멘트: 머지한다'
rm -f "$WIN/89.jsonl" "$WIN/89.posted"
rec '- 5라운드 코멘트: 머지한다'
STUB_FAIL='pr comment' post "gh 가 실패하면 실패로 끝난다" 1
post "실패한 기록은 다음에 올린다" 0
body_is "실패한 기록이 남아 있다" '- 5라운드 코멘트: 머지한다'
rec '- 6라운드 코멘트: 머지한다'
post "봇 설정이 없으면 올리지 않는다" 2 "$T/plain"
# 세션의 cwd 는 레포의 하위 디렉터리일 수 있다. 기록은 그래도 레포의 git 디렉터리에서 읽는다
mkdir -p "$T/bot/sub/deep"
post "하위 디렉터리에서 불러도 레포의 기록을 올린다" 0 "$T/bot/sub/deep"
body_is "하위 디렉터리에서 올린 본문" '- 6라운드 코멘트: 머지한다'
rec '- 7라운드 코멘트: 머지한다'
post "-R 로 준 레포에 올린다" 0 "$T/bot" -R 4estse4/other
if grep -qF -- 'pr comment 89 -R 4estse4/other --body-file' "$T/gh-args"; then echo "  ✓ 올리기: -R 을 gh 에 전달한다"
else echo "  ✗ 올리기: -R 을 전달하지 않았다: $(cat "$T/gh-args")"; fail=1; fi
post "옛 모양(본문 파일 · sha256)으로 부르면 사용법을 낸다" 2 "$T/bot" /tmp/x.md 0000
post "PR 번호 뒤에 본문 파일 하나만 주면 사용법을 낸다" 2 "$T/bot" /tmp/x.md
post "-R 뒤에 인자를 더 주면 사용법을 낸다" 2 "$T/bot" -R 4estse4/other /tmp/x.md

[ "$fail" = 0 ] && echo "  ✓ 봇 설정이 있으면 사람 계정 코멘트와 사람의 Approve 로 사람의 결정을 확인한다"
exit "$fail"
