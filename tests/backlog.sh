#!/usr/bin/env bash
# 「다음 일」을 고를 때 받는 목록(`claude-code/hooks/backlog.sh`)이 열린 이슈 전부와 다른 세션이 맡은 일을 내는가.
#
# 이 테스트가 있는 이유: 「다음 일」 보기가 하던 묶음의 다음 차례에서만 나와, 하드룰을 지키는 장치의 구멍인 이슈가
# 한 번도 보기에 오르지 않았다(이슈 #208). 그래서 「다음 일」을 고를 때마다 열린 이슈 전체를 다시 받는다. 받는 쪽이
# 틀리면 고르는 규칙이 맞아도 후보가 빠진다. 보는 것:
#   · `gh issue list` 의 기본 30건에서 잘리지 않고 열린 이슈를 모두 낸다. 받은 수가 한도에 닿으면 실패한다
#   · 열린 PR 은 닫는 이슈와 본문의 `Refs #N` 만 뺄 번호로 낸다. PR 본문은 `Refs` 를 문장이나 괄호 안에 적으므로
#     줄 어디서든 읽고, 뒤에 이은 번호도 읽는다. 본문이 근거로 든 다른 번호는 빼지 않는다 — 빼면 그 PR 이 열려 있는
#     동안 근거로 든 이슈가 후보에서 빠진다
#   · PR 이 없는 다른 worktree 의 브랜치는 기본 브랜치에 없는 커밋의 메시지에서 줄 머리의 닫는 키워드(Closes · Fixes ·
#     Resolves 꼴)나 `Refs` 뒤에 이은 번호만 뺄 번호로 낸다. 줄을 넘은 번호와 다른 레포의 번호는 읽지 않는다. 그 밖의 번호는 그 worktree 줄에 근거로 든 번호로 보이고 빼지 않는다 —
#     빼면 다른 세션이 계획 커밋에서 근거로만 든 이슈가 후보에서 빠진다(이슈 #215). 커밋에 그런 키워드가 하나도 없으면
#     맡은 이슈를 알 단서가 번호뿐이라 번호를 모두 낸다. 번호가 없으면 브랜치 이름을 그대로 낸다. PR 이 있는 브랜치는
#     PR 쪽 규칙을 따른다
#   · 열린 PR 은 없고 팁이 머지되거나 닫힌 PR 의 head 에 든(head 와 같거나 그 조상인) 브랜치는 끝난 일이라 번호를
#     빼지 않는다. 이름만 같고 팁이 그 head 뒤로 나아간 브랜치는 새 일이라 번호를 뺀다
#   · 이 스크립트를 실행한 worktree(세션 자신의 일), 기본 브랜치에 없는 커밋이 없는 detach worktree, 기본 브랜치의
#     worktree 는 다른 세션의 일로 내지 않는다
#   · 뺄 번호는 열린 이슈인 것만 낸다
#   · `gh` 가 실패하거나 기본 브랜치를 모르면 그 사실을 `!!` 줄로 내고 0 이 아닌 코드로 끝난다. 그 줄은 세션이
#     사람에게 그대로 보이므로 글자까지 본다
#
# **네트워크를 안 쓴다.** PATH 앞에 둔 가짜 `gh` 가 `--limit` 을 따라(없으면 30건) 열린 이슈와 PR 을 돌려준다.
set -u
unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/claude-code/hooks/backlog.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
joined = ' '.join(a)
fail = os.environ.get('STUB_FAIL', '')
if fail and fail in joined:
    sys.stderr.write('HTTP 502: Bad Gateway\n')
    sys.exit(1)
limit = 30
for flag in ('--limit', '-L'):
    if flag in a:
        limit = int(a[a.index(flag) + 1])
if a[:2] == ['issue', 'list']:
    total = int(os.environ.get('STUB_ISSUES', '45'))
    issues = [{'number': n, 'title': '이슈 %d' % n, 'updatedAt': '2026-10-10T00:00:00Z', 'comments': [{}] * (n % 3)}
              for n in range(total, 0, -1)]
    print(json.dumps(issues[:limit], ensure_ascii=False))
    sys.exit(0)
if a[:2] == ['pr', 'list']:
    prs = [{'number': 300, 'title': 'PR 셋백', 'headRefName': 'feat/c', 'state': 'OPEN',
            'closingIssuesReferences': [{'number': 40}],
            'body': '근거로 든 것: #41 · #42. 이 PR 은 이슈 #45 를 닫지 않는다. Refs #45.\n\n'
                    '- 이 PR 은 이슈를 닫지 않는다(Refs #8, #9 and #10).\n\nRefs #43\nrefs: #44'},
           {'number': 301, 'title': '머지된 PR', 'headRefName': 'feat/merged', 'state': 'MERGED',
            'headRefOid': os.environ.get('STUB_OID_MERGED', ''), 'closingIssuesReferences': [], 'body': 'Refs #14'},
           {'number': 302, 'title': '닫힌 PR', 'headRefName': 'feat/closed', 'state': 'CLOSED',
            'headRefOid': os.environ.get('STUB_OID_CLOSED', ''), 'closingIssuesReferences': [], 'body': 'Refs #15'},
           # 머지된 PR — 그 브랜치에 이어 커밋해 새 일을 한다. 팁이 그 head 의 뒤에 있다
           {'number': 303, 'title': '예전 PR', 'headRefName': 'feat/reused', 'state': 'MERGED',
            'headRefOid': os.environ.get('STUB_OID_REUSED', ''), 'closingIssuesReferences': [], 'body': ''},
           # 머지된 PR — worktree 의 팁이 그 head 의 조상이다(다른 곳에서 head 가 앞으로 갔다)
           {'number': 304, 'title': '앞서간 PR', 'headRefName': 'feat/behind', 'state': 'MERGED',
            'headRefOid': os.environ.get('STUB_OID_BEHIND', ''), 'closingIssuesReferences': [], 'body': ''}]
    if '--head' in a:
        prs = [p for p in prs if p['headRefName'] == a[a.index('--head') + 1]]
    state = a[a.index('--state') + 1] if '--state' in a else 'open'
    if state != 'all':
        prs = [p for p in prs if p['state'].lower() == state]
    print(json.dumps(prs[:limit], ensure_ascii=False))
    sys.exit(0)
sys.stderr.write('stub: 모르는 호출 %s\n' % joined)
sys.exit(2)
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# 원격(bare)에서 clone 한 체크아웃이 이 세션이다. 다른 worktree 는 다른 세션의 일인 것과, 끝났거나 하는 일이
# 없어 다른 세션의 일로 내지 않는 것을 섞어 둔다
git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/self" 2>/dev/null
git -C "$T/self" commit -q --allow-empty -m init
git -C "$T/self" push -q origin main 2>/dev/null
git -C "$T/self" remote set-head origin --auto >/dev/null 2>&1
# 세션 자신의 브랜치 — 그 커밋이 말하는 번호는 빼지 않는다
git -C "$T/self" switch -q -c feat/self
git -C "$T/self" commit -q --allow-empty -m 'work on my own issue (Refs #7)'
# PR 이 없고 커밋 본문이 닫는 키워드 없이 번호를 말하는 브랜치. 열린 이슈가 아닌 번호도 하나 말한다
git -C "$T/self" worktree add -q -b feat/a "$T/wt-a" main
git -C "$T/wt-a" commit -q --allow-empty -m 'fix the hook' -m 'the commit hook blocked every commit (issue #12). like PR #999.'
# PR 이 없고 커밋이 Refs · 닫는 키워드로 맡은 이슈를 적은 브랜치. 첫 커밋은 이슈 #215 의 계획 커밋 꼴이다 — 본문이
# 순서의 근거로 다른 번호를 들고 끝에 `Refs` 를 적는다. 닫는 키워드는 대소문자와 콜론이 다른 두 꼴을 둔다
git -C "$T/self" worktree add -q -b feat/d "$T/wt-d" main
git -C "$T/wt-d" commit -q --allow-empty -m 'docs(plan): write the order' \
  -m 'The next-task window ranked #20 first. #21 and #22 follow, since #20 blocks them.' -m 'Refs #23'
git -C "$T/wt-d" commit -q --allow-empty -m 'fix the gate' -m 'Closes #24'
git -C "$T/wt-d" commit -q --allow-empty -m 'test the gate' -m 'fixes: #25'
# 키워드 하나 뒤에 번호를 여럿 이은 꼴 — 이 레포의 커밋에 실제로 있다. 이은 번호를 모두 뺀다
git -C "$T/self" worktree add -q -b feat/e "$T/wt-e" main
git -C "$T/wt-e" commit -q --allow-empty -m 'close three' -m 'Closes #26, #27 and #28.'
git -C "$T/wt-e" commit -q --allow-empty -m 'refer two' -m 'Refs #29, #30'
# 키워드가 줄 머리가 아니라 산문 · 인용 속에 있거나, 줄을 넘어 번호가 다음 줄에 오는 꼴 — 다른 일을 설명하는 것이라
# 빼지 않는다. 이 브랜치가 맡은 것은 줄 머리의 `Refs #33` 이다
git -C "$T/self" worktree add -q -b feat/f "$T/wt-f" main
git -C "$T/wt-f" commit -q --allow-empty -m 'explain' \
  -m 'This is the same fix #31 asked for; #32 follows. gh still returns "Closes #34" for the earlier PR.' \
  -m "$(printf 'The gate change also fixes\n#35 bypass, so it comes next.')" -m 'Refs #33'
# 줄 머리의 키워드라도 줄을 넘은 번호는 읽지 않는다(#36 · #38). 앞에 공백이 있는 줄 머리는 읽는다(#39). 다른 레포의
# 번호는 이 레포의 이슈가 아니라 읽지 않는다(#18)
git -C "$T/wt-f" commit -q --allow-empty -m 'wrap' -m "$(printf 'Closes\n#36 is the one after.')" \
  -m "$(printf 'Refs #37,\n#38 waits for it.')" -m '  Refs #39' -m 'Refs other/kit#18'
# PR 이 없고 번호도 없는 브랜치
git -C "$T/self" worktree add -q -b feat/b "$T/wt-b" main
git -C "$T/wt-b" commit -q --allow-empty -m 'start something'
# 열린 PR(#300)이 있는 브랜치 — 커밋이 말하는 번호가 아니라 PR 의 닫는 이슈와 Refs 를 따른다
git -C "$T/self" worktree add -q -b feat/c "$T/wt-c" main
git -C "$T/wt-c" commit -q --allow-empty -m 'as discussed in #13'
# PR 이 이미 머지된(또는 닫힌) 브랜치가 worktree 에 남은 것 — 스쿼시 머지라 그 커밋은 기본 브랜치의 조상이 아니다.
# 그 커밋이 가리키는 열린 이슈는 아무도 하고 있지 않으므로 빼지 않는다
git -C "$T/self" worktree add -q -b feat/merged "$T/wt-merged" main
git -C "$T/wt-merged" commit -q --allow-empty -m 'first part' -m 'Refs #14'
git -C "$T/self" worktree add -q -b feat/closed "$T/wt-closed" main
git -C "$T/wt-closed" commit -q --allow-empty -m 'abandoned' -m 'Refs #15'
export STUB_OID_MERGED=$(git -C "$T/wt-merged" rev-parse HEAD) STUB_OID_CLOSED=$(git -C "$T/wt-closed" rev-parse HEAD)
# 머지된 PR(#303)의 브랜치에 이어 커밋해 새 일을 하는 것 — 팁이 그 head 에 들어 있지 않으니 끝난 일이 아니다.
# head 를 레포에 있는 커밋으로 둬서 조상 판정이 실제로 실행되게 한다
git -C "$T/self" worktree add -q -b feat/reused "$T/wt-reused" main
git -C "$T/wt-reused" commit -q --allow-empty -m 'old work'
export STUB_OID_REUSED=$(git -C "$T/wt-reused" rev-parse HEAD)
git -C "$T/wt-reused" commit -q --allow-empty -m 'new work' -m 'for issue #16'
# 머지된 PR(#304)의 head 가 worktree 의 팁보다 앞에 있는 것 — 팁이 그 head 에 들어 있으니 끝난 일이다
git -C "$T/self" worktree add -q -b feat/behind "$T/wt-behind" main
git -C "$T/wt-behind" commit -q --allow-empty -m 'part one' -m 'Refs #17'
# PR 의 head 는 그 팁에 커밋 하나를 더한 것이다. 브랜치로 남겨 객체가 레포에 있게 한다(worktree 가 아니라 목록에 안 나온다)
behind=$(git -C "$T/wt-behind" rev-parse HEAD)
export STUB_OID_BEHIND=$(git -C "$T/self" commit-tree -p "$behind" -m 'part two' "$(git -C "$T/self" rev-parse "$behind^{tree}")")
git -C "$T/self" branch -q pr304-head "$STUB_OID_BEHIND"
# `merge-pr` 4절대로 정리를 마치고 기본 브랜치에 detach 한 worktree, 기본 브랜치에 있는 worktree — 하는 일이 없다
git -C "$T/self" worktree add -q --detach "$T/wt-done" main
git -C "$T/self" worktree add -q "$T/wt-main" main

run() { ( cd "$T/self" && bash "$S" ) > "$T/out" 2>&1; echo $? > "$T/rc"; }

if [ ! -f "$S" ]; then
  bad "claude-code/hooks/backlog.sh 가 없다"
  exit 1
fi

run
rc=$(cat "$T/rc")
[ "$rc" = 0 ] && ok "열린 이슈 · PR · worktree 를 받으면 0 으로 끝난다" || { bad "rc=$rc 로 끝났다:"; sed 's/^/      /' "$T/out"; }
missing=$(python3 - "$T/out" <<'PY'
import re, sys
out = open(sys.argv[1], encoding='utf-8').read()
sec = out.split('== 열린 이슈', 1)[1].split('\n==', 1)[0] if '== 열린 이슈' in out else ''
got = set(int(n) for n in re.findall(r'^#(\d+)\t', sec, re.M))
print(' '.join(str(n) for n in range(1, 46) if n not in got))
PY
)
[ -z "$missing" ] && ok "기본 30건을 넘는 열린 이슈 45건을 모두 낸다" || bad "열린 이슈 가운데 빠진 번호가 있다: $missing"

drop=$(sed -n '/^== 후보에서 뺄 열린 이슈/,/^==/p' "$T/out")
has() { printf '%s\n' "$drop" | grep -qE "^#$1([^0-9]|$)"; }
for n in 40 43 44; do
  has $n && ok "열린 PR 의 닫는 이슈 · Refs 번호(#$n)를 뺄 번호로 낸다" || bad "열린 PR 의 닫는 이슈 · Refs 번호(#$n)가 뺄 번호에 없다"
done
for n in 41 42; do
  has $n && bad "PR 본문이 근거로 든 번호(#$n)를 뺄 번호로 냈다" || ok "PR 본문이 근거로 든 번호(#$n)는 빼지 않는다"
done
for n in 45 8 9 10; do
  has $n && ok "PR 본문의 문장 · 괄호 안에 적은 Refs 번호(#$n)를 뺄 번호로 낸다" \
    || bad "PR 본문의 문장 · 괄호 안에 적은 Refs 번호(#$n)가 뺄 번호에 없다"
done
for n in 26 27 28 29 30; do
  has $n && ok "키워드 하나 뒤에 이은 번호(#$n)를 모두 뺄 번호로 낸다" || bad "키워드 하나 뒤에 이은 번호(#$n)가 뺄 번호에 없다"
done
for n in 33 37 39; do
  has $n && ok "줄 머리(앞 공백 포함)의 Refs 번호(#$n)를 뺄 번호로 낸다" || bad "줄 머리(앞 공백 포함)의 Refs 번호(#$n)가 뺄 번호에 없다"
done
for n in 31 32 34 35 36 38; do
  has $n && bad "산문 · 인용 속이나 줄을 넘은 키워드 뒤의 번호(#$n)를 뺄 번호로 냈다" \
    || ok "산문 · 인용 속이나 줄을 넘은 키워드 뒤의 번호(#$n)는 빼지 않는다"
done
has 18 && bad "다른 레포의 번호(other/kit#18)를 이 레포의 이슈로 보고 뺄 번호로 냈다" \
  || ok "다른 레포의 번호(other/kit#18)는 이 레포의 이슈로 보지 않는다"
has 12 && ok "PR 이 없는 worktree 의 커밋에 닫는 키워드 · Refs 가 없으면 커밋 본문이 말한 #12 를 뺄 번호로 낸다" \
  || bad "PR 이 없는 worktree 의 커밋에 닫는 키워드 · Refs 가 없는데 커밋 본문이 말한 #12 가 뺄 번호에 없다"
grep -E 'feat/a' "$T/out" | grep -q '닫는 키워드 · Refs 가 없어' \
  && ok "닫는 키워드 · Refs 가 없어 번호를 모두 뺀 worktree(feat/a)는 줄에 그 까닭을 적는다" \
  || bad "닫는 키워드 · Refs 가 없는 worktree(feat/a)의 줄에 까닭이 없다: $(grep -E 'feat/a' "$T/out")"
for n in 23 24 25; do
  has $n && ok "PR 이 없는 worktree 의 커밋이 Refs · 닫는 키워드로 적은 번호(#$n)를 뺄 번호로 낸다" \
    || bad "PR 이 없는 worktree 의 커밋이 Refs · 닫는 키워드로 적은 번호(#$n)가 뺄 번호에 없다"
done
for n in 20 21 22; do
  has $n && bad "PR 이 없는 worktree 의 커밋이 근거로만 든 번호(#$n)를 뺄 번호로 냈다" \
    || ok "PR 이 없는 worktree 의 커밋이 근거로만 든 번호(#$n)는 빼지 않는다"
done
dline=$(grep -E 'feat/d' "$T/out")
printf '%s\n' "$dline" | grep -q '빼는 번호 #23 #24 #25' && printf '%s\n' "$dline" | grep -q '근거로 든 번호 #20 #21 #22' \
  && ok "worktree 줄에 빼는 번호와 근거로 든 번호를 나눠 보인다" \
  || bad "worktree(feat/d) 줄이 빼는 번호와 근거로 든 번호를 나눠 보이지 않는다: $dline"
has 999 && bad "열린 이슈가 아닌 #999 를 뺄 번호로 냈다" || ok "열린 이슈가 아닌 번호는 뺄 번호로 내지 않는다"
has 13 && bad "PR 이 있는 브랜치의 커밋이 말한 #13 을 뺄 번호로 냈다" || ok "PR 이 있는 브랜치는 커밋이 아니라 PR 을 따른다"
has 7 && bad "이 세션 자신의 브랜치가 말한 #7 을 뺄 번호로 냈다" || ok "이 스크립트를 실행한 worktree 는 다른 세션의 일로 내지 않는다"
grep -E 'feat/b' "$T/out" | grep -q '번호 없음' && ok "번호가 없는 worktree 브랜치를 이름 그대로 낸다" \
  || bad "번호가 없는 worktree 브랜치(feat/b)가 출력에 없다"
grep -q 'feat/self' "$T/out" && bad "이 세션 자신의 브랜치(feat/self)를 다른 worktree 로 냈다" || ok "이 세션 자신의 브랜치는 worktree 목록에 없다"
for c in '14:feat/merged:머지됨' '15:feat/closed:닫힘'; do
  n=${c%%:*}; rest=${c#*:}; br=${rest%%:*}; st=${rest#*:}
  has "$n" && bad "PR 이 끝난 브랜치(${br})의 커밋이 가리키는 번호(#${n})를 뺄 번호로 냈다" \
    || ok "PR 이 끝난 브랜치(${br})의 커밋이 가리키는 번호(#${n})는 빼지 않는다"
  grep -E "${br}" "$T/out" | grep -q "${st}" && ok "PR 이 끝난 브랜치(${br})를 「${st}」으로 낸다" \
    || bad "PR 이 끝난 브랜치(${br})가 「${st}」으로 나오지 않는다: $(grep -E "${br}" "$T/out")"
done
grep -q 'wt-done' "$T/out" && bad "정리를 마치고 detach 한 worktree(wt-done)를 다른 세션의 일로 냈다" \
  || ok "기본 브랜치에 없는 커밋이 없는 detach worktree 는 내지 않는다"
grep -q 'wt-main' "$T/out" && bad "기본 브랜치에 있는 worktree(wt-main)를 다른 세션의 일로 냈다" \
  || ok "기본 브랜치에 있는 worktree 는 내지 않는다"
has 16 && ok "머지된 PR 의 브랜치에 이어 새 일을 한 worktree(feat/reused)가 말하는 번호(#16)를 뺄 번호로 낸다" \
  || bad "머지된 PR 의 브랜치에 이어 새 일을 한 worktree(feat/reused)를 끝난 일로 봤다: $(grep -E 'feat/reused' "$T/out")"
has 17 && bad "팁이 머지된 PR 의 head 에 든 worktree(feat/behind)의 번호(#17)를 뺄 번호로 냈다: $(grep -E 'feat/behind' "$T/out")" \
  || ok "팁이 머지된 PR 의 head 에 든 worktree(feat/behind)는 끝난 일이라 그 번호(#17)를 빼지 않는다"

# 받은 수가 한도에 닿으면 잘렸을 수 있다 — 잘린 목록으로 고르지 않게 실패한다
STUB_ISSUES=100000 run
rc=$(cat "$T/rc")
[ "$rc" != 0 ] && grep -q '^!!' "$T/out" && ok "열린 이슈 수가 한도에 닿으면 그 사실을 내고 실패한다" \
  || bad "열린 이슈 수가 한도에 닿았는데 rc=$rc: $(head -1 "$T/out")"

# 실패 줄은 세션이 사람에게 그대로 보인다 — 조사까지 앞말에 맞는지 본다
for c in 'issue list:!! 열린 이슈를 받지 못했다' 'pr list:!! 열린 PR 을 받지 못했다' '--head:!! feat/'; do
  what=${c%%:*}; want=${c#*:}
  STUB_FAIL="$what" run
  rc=$(cat "$T/rc")
  [ "$rc" != 0 ] && grep -qF "$want" "$T/out" && ok "\`gh\` 조회(${what})가 실패하면 「${want}」 줄을 내고 실패한다" \
    || bad "\`gh\` 조회(${what})가 실패했는데 rc=$rc: $(head -1 "$T/out")"
done

# 기본 브랜치를 모르면 어느 커밋이 그 브랜치의 일인지 가리지 못한다
git -C "$T/self" remote set-head origin --delete >/dev/null 2>&1
run
rc=$(cat "$T/rc")
[ "$rc" != 0 ] && grep -q '^!!' "$T/out" && ok "origin 의 기본 브랜치를 모르면 그 사실을 내고 실패한다" \
  || bad "origin/HEAD 가 없는데 rc=$rc: $(head -1 "$T/out")"

bash -n "$S" && ok "구문 검사를 통과한다" || bad "구문 검사를 통과한다"
[ "$fail" = 0 ] && echo "  ✓ 「다음 일」 목록이 열린 이슈 전부와 다른 세션의 일을 낸다"
exit $fail
