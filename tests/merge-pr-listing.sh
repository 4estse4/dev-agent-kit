#!/usr/bin/env bash
# merge-pr 2절 「리뷰 반영 확인」의 나열이 base 를 합친 브랜치에서 이 PR 의 커밋만 내고, 머지 커밋에서
# 충돌을 푼 것을 보이는가.
#
# 이 테스트가 있는 이유: 나열이 `git log <라운드 head>..<head> --name-only` 였을 때, Approve 뒤 base 가 바뀌어
# base 를 합친 PR 에서 base 로 들어온 다른 PR 의 커밋이 이 PR 의 리뷰를 거치지 않은 커밋으로 나왔고, 충돌을 푼
# 머지 커밋은 파일 없이 나왔다. 그래서 결정 코멘트가 그 커밋을 손으로 풀어 적었다. `--first-parent` 로 base 의
# 커밋을 빼면 base 가 아닌 브랜치를 합친 머지에서 그 브랜치의 커밋까지 빠진다.
#
# 스킬 글에서 명령(fetch · 나열 · 머지 커밋 보기)을 꺼내, 라운드 head 뒤에 base 를 세 번 합치고 base 가 아닌
# 브랜치를 한 번 합친 브랜치에서 실행한다. 실행하는 clone 은 base 를 둘째 커밋까지만 받아 두고 PR 브랜치의
# 객체는 없어서, base 의 셋째 커밋과 PR 브랜치는 스킬의 fetch 로만 받는다. 보는 것:
#   · base 로 들어온 커밋은 나열에 나오지 않는다. 받아 둔 옛 base 에 없던 커밋도 나오지 않는다
#   · 라운드 head 뒤 이 브랜치의 커밋과 base 가 아닌 브랜치의 커밋은 건드린 파일과 함께 나온다
#   · 머지 커밋은 부모 둘과 함께 나오고, 파일은 자동 머지와 다르게 된 것만 나온다 — 충돌을 푼 파일 · 머지하면서
#     고친 파일. 충돌 없이 합친 머지는 파일 없이 나온다
#   · 머지 커밋 보기가 충돌을 푼 머지에서 충돌 표시와 푼 줄을, 머지하면서 고친 머지에서 고친 줄을 보이고,
#     충돌 없이 합친 머지에서는 머리 한 줄만 낸다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# 스킬은 `SKILL.md` 와 보조 파일로 나뉘므로 스킬 디렉터리의 `.md` 를 모두 이어 읽는다
SK="$T/merge-pr.md"
awk 1 "$KIT"/claude-code/skills/merge-pr/*.md > "$SK"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
gc() { git -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false "$@"; }

FETCH=$(grep -E '^ +git fetch origin <headRefName>' "$SK" | head -1 | sed 's/^ *//')
LIST=$(grep -E '^ +git log .*<그 head>\.\.<headRefOid>' "$SK" | head -1 | sed 's/^ *//')
SHOW=$(grep -E '^ +git show .*<머지 커밋>' "$SK" | head -1 | sed 's/^ *//')
[ -n "$FETCH" ] || bad "2절에서 fetch 명령(git fetch origin <headRefName>)을 찾지 못했다"
[ -n "$LIST" ] || bad "2절에서 나열 명령(git log … <그 head>..<headRefOid>)을 찾지 못했다"
[ "$fail" = 0 ] || exit 1
[ -n "$SHOW" ] || bad "2절에서 머지 커밋 보기 명령(git show … <머지 커밋>)을 찾지 못했다"

# ── setup: bare origin · 작업 clone · 실행할 clone(base 를 합치기 전에 main 만 받는다)
O="$T/origin.git"; W="$T/work"; C="$T/check"
git init -q --bare -b main "$O"
git clone -q "$O" "$W" 2>/dev/null
cd "$W" || exit 1
printf '# dev-log\n\n## A\n' > dev.md; echo f0 > f.txt; echo g0 > g.txt; echo h0 > h.txt
git add . && gc commit -qm init && git push -q origin main 2>/dev/null
git clone -q --single-branch -b main "$O" "$C" 2>/dev/null
ROOT=$(git rev-parse HEAD)

git switch -qc feat/x
printf '# dev-log\n\n## A\n\n## X\n' > dev.md; echo f1 > f.txt
gc commit -qam 'x: f and dev-log'; RH=$(git rev-parse HEAD)   # 라운드 head

base() { # $1=제목 $2=파일 $3=내용 — main 에 다른 PR 의 스쿼시 커밋을 둔다
  git switch -q main && printf '%b' "$3" > "$2" && gc commit -qam "$1" && git push -q origin main 2>/dev/null
  git switch -q feat/x
}
base 'base one (#1)' dev.md '# dev-log\n\n## A\n\n## ONE\n'
gc merge -q origin/main >/dev/null 2>&1   # dev.md 가 부딪힌다
printf '# dev-log\n\n## A\n\n## ONE\n\n## X\n' > dev.md; git add dev.md
gc commit -qm 'Merge base: conflict'; M_CONFLICT=$(git rev-parse HEAD)
echo f2 > f.txt; gc commit -qam 'x: after merge'
base 'base two (#2)' h.txt 'h1\n'
gc merge -q --no-edit -m 'Merge base: clean' origin/main; M_CLEAN=$(git rev-parse HEAD)
git -C "$C" fetch -q origin main 2>/dev/null   # 실행할 clone 이 받아 둔 base 는 여기까지다
BASE_SEEN=$(git rev-parse origin/main)
base 'base three (#3)' g.txt 'g1\n'
gc merge -q --no-commit origin/main 2>/dev/null; echo f3 > f.txt; git add f.txt
gc commit -qm 'Merge base: edited'; M_EDITED=$(git rev-parse HEAD)
git switch -qc side "$ROOT" && echo s > s.txt && git add s.txt && gc commit -qm 'side: s'
git switch -q feat/x && gc merge -q --no-edit -m 'Merge side' side
git push -q origin feat/x 2>/dev/null
HEAD_OID=$(git rev-parse HEAD)
if [ "$(git -C "$C" rev-parse origin/main)" != "$BASE_SEEN" ] || git -C "$C" cat-file -e "$HEAD_OID" 2>/dev/null; then
  bad "setup: 실행할 clone 이 base 를 둘째 커밋까지만 받고 PR 브랜치의 객체는 없어야 한다"; exit 1
fi

sub() { # $1=스킬의 명령 $2=머지 커밋 — 자리 표시를 이 레포의 값으로 바꾼다
  printf '%s' "$1" | sed -e "s|<그 head>|$RH|g" -e "s|<headRefOid>|$HEAD_OID|g" -e "s|<headRefName>|feat/x|g" \
    -e "s|<baseRefName>|main|g" -e "s|<머지 커밋>|${2:-}|g"
}
run() { (cd "$C" && eval "$(sub "$1" "${2:-}")") 2>&1; }

out=$(run "$FETCH"; run "$LIST")
case "$out" in *'rc=0'*) ;; *) bad "fetch · 나열이 rc=0 으로 끝나지 않았다: [$out]" ;; esac
case "$out" in *rc=[1-9]*) bad "fetch · 나열 가운데 실패한 것이 있다: [$out]" ;; esac

SUBJECTS='x: f and dev-log|x: after merge|Merge base: conflict|Merge base: clean|Merge base: edited|Merge side|side: s|base one (#1)|base two (#2)|base three (#3)'
files_of() { # $1=제목 — 나열에서 그 커밋 줄 아래의 파일 줄을 공백으로 이어 낸다. 커밋 줄이 없으면 「없음」
  printf '%s\n' "$out" | awk -v s="$1" -v subs="$SUBJECTS" '
    BEGIN { n = split(subs, a, "|") }
    { hit = 0; for (i = 1; i <= n; i++) if (index($0, a[i])) { hit = 1; cur = a[i] } }
    hit { if (cur == s) seen = 1; next }
    cur == s && NF && $0 !~ /^rc=/ && $0 !~ /^From / && $0 !~ /->/ { printf "%s ", $1 }
    END { if (!seen) printf "없음" }' | sed 's/ $//'
}
want() { # $1=설명 $2=제목 $3=기대하는 파일 목록(「없음」은 나오지 않아야 한다)
  got=$(files_of "$2")
  if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 — 「$2」의 파일이 [$3] 이어야 하는데 [$got]"; fi
}

echo "── 나열"
want "base 로 들어온 첫 커밋은 나오지 않는다" 'base one (#1)' '없음'
want "base 로 들어온 둘째 커밋은 나오지 않는다" 'base two (#2)' '없음'
want "fetch 전에 받아 둔 base 에 없던 커밋도 나오지 않는다" 'base three (#3)' '없음'
want "라운드 head 는 나오지 않는다" 'x: f and dev-log' '없음'
want "라운드 head 뒤 이 브랜치의 커밋은 파일과 함께 나온다" 'x: after merge' 'f.txt'
want "충돌을 푼 머지 커밋은 충돌을 푼 파일만 나온다(base 가 바꾼 다른 파일은 나오지 않는다)" 'Merge base: conflict' 'dev.md'
want "충돌 없이 합친 머지 커밋은 파일 없이 나온다" 'Merge base: clean' ''
want "머지하면서 고친 머지 커밋은 고친 파일이 나온다" 'Merge base: edited' 'f.txt'
want "base 가 아닌 브랜치를 합친 머지 커밋은 파일 없이 나온다" 'Merge side' ''
want "base 가 아닌 브랜치의 커밋은 파일과 함께 나온다" 'side: s' 's.txt'
p2=$(git log -1 --format=%p "$M_CONFLICT" | cut -d' ' -f2)
line=$(printf '%s\n' "$out" | grep -F 'Merge base: conflict')
case "$line" in
  *"$p2"*) ok "머지 커밋 줄에 둘째 부모가 나와 머지 커밋인 것이 보인다" ;;
  *) bad "머지 커밋 줄에 둘째 부모($p2)가 없다: [$line]" ;;
esac

echo "── 머지 커밋 보기"
[ -n "$SHOW" ] || exit 1
s=$(run "$SHOW" "$M_CONFLICT")
if printf '%s\n' "$s" | grep -q '^-<<<<<<<' && printf '%s\n' "$s" | grep -q '^+## X'; then
  ok "충돌을 푼 머지에서 충돌 표시와 푼 줄을 보인다"
else bad "충돌을 푼 머지에서 충돌 표시(-<<<<<<<)와 푼 줄(+## X)이 보여야 한다: [$s]"; fi
s=$(run "$SHOW" "$M_EDITED")
if printf '%s\n' "$s" | grep -q '^+f3'; then ok "머지하면서 고친 머지에서 고친 줄을 보인다"
else bad "머지하면서 고친 머지에서 고친 줄(+f3)이 보여야 한다: [$s]"; fi
s=$(run "$SHOW" "$M_CLEAN" | grep -v '^rc=' | sed '/^$/d')
if [ "$(printf '%s\n' "$s" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$s" | grep -q 'Merge base: clean'; then
  ok "충돌 없이 합친 머지에서는 머리 한 줄만 낸다"
else bad "충돌 없이 합친 머지에서는 머리 한 줄만 나와야 한다: [$s]"; fi

exit $fail
