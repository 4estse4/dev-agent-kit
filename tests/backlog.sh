#!/usr/bin/env bash
# 「다음 일」을 고를 때 받는 목록(`claude-code/hooks/backlog.sh`)이 열린 이슈 전부와 다른 세션이 맡은 일을 내는가.
#
# 이 테스트가 있는 이유: 「다음 일」 보기가 하던 묶음의 다음 차례에서만 나와, 하드룰을 지키는 장치의 구멍인 이슈가
# 한 번도 보기에 오르지 않았다(이슈 #208). 그래서 「다음 일」을 고를 때마다 열린 이슈 전체를 다시 받는다. 받는 쪽이
# 틀리면 고르는 규칙이 맞아도 후보가 빠진다. 보는 것:
#   · `gh issue list` 의 기본 30건에서 잘리지 않고 열린 이슈를 모두 낸다. 받은 수가 한도에 닿으면 실패한다
#   · 열린 PR 은 닫는 이슈와 본문의 `Refs #N` 만 뺄 번호로 낸다. 본문이 근거로 든 다른 번호는 빼지 않는다 —
#     빼면 그 PR 이 열려 있는 동안 근거로 든 이슈가 후보에서 빠진다
#   · PR 이 없는 다른 worktree 의 브랜치는 기본 브랜치에 없는 커밋의 메시지에 나오는 번호를 꼴을 가리지 않고 낸다.
#     번호가 없으면 브랜치 이름을 그대로 낸다. PR 이 있는 브랜치는 PR 쪽 규칙을 따른다
#   · 이 스크립트를 실행한 worktree(세션 자신의 일)는 다른 세션의 일로 내지 않는다
#   · 뺄 번호는 열린 이슈인 것만 낸다
#   · `gh` 가 실패하거나 기본 브랜치를 모르면 그 사실을 내고 0 이 아닌 코드로 끝난다
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
    prs = [{'number': 300, 'title': 'PR 셋백', 'headRefName': 'feat/c',
            'closingIssuesReferences': [{'number': 40}],
            'body': '근거로 든 것: #41 · #42\n\nRefs #43\nrefs: #44'}]
    print(json.dumps(prs[:limit], ensure_ascii=False))
    sys.exit(0)
sys.stderr.write('stub: 모르는 호출 %s\n' % joined)
sys.exit(2)
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# 원격(bare)에서 clone 한 체크아웃이 이 세션이고, 다른 worktree 셋이 다른 세션의 일이다
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
# PR 이 없고 번호도 없는 브랜치
git -C "$T/self" worktree add -q -b feat/b "$T/wt-b" main
git -C "$T/wt-b" commit -q --allow-empty -m 'start something'
# 열린 PR(#300)이 있는 브랜치 — 커밋이 말하는 번호가 아니라 PR 의 닫는 이슈와 Refs 를 따른다
git -C "$T/self" worktree add -q -b feat/c "$T/wt-c" main
git -C "$T/wt-c" commit -q --allow-empty -m 'as discussed in #13'

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
  has $n && ok "열린 PR 의 닫는 이슈 · Refs 인 #$n 을 뺄 번호로 낸다" || bad "열린 PR 의 닫는 이슈 · Refs 인 #$n 이 뺄 번호에 없다"
done
for n in 41 42; do
  has $n && bad "PR 본문이 근거로 든 #$n 을 뺄 번호로 냈다" || ok "PR 본문이 근거로 든 #$n 은 빼지 않는다"
done
has 12 && ok "PR 이 없는 worktree 의 커밋 본문이 닫는 키워드 없이 말한 #12 를 뺄 번호로 낸다" \
  || bad "PR 이 없는 worktree 의 커밋 본문이 말한 #12 가 뺄 번호에 없다"
has 999 && bad "열린 이슈가 아닌 #999 를 뺄 번호로 냈다" || ok "열린 이슈가 아닌 번호는 뺄 번호로 내지 않는다"
has 13 && bad "PR 이 있는 브랜치의 커밋이 말한 #13 을 뺄 번호로 냈다" || ok "PR 이 있는 브랜치는 커밋이 아니라 PR 을 따른다"
has 7 && bad "이 세션 자신의 브랜치가 말한 #7 을 뺄 번호로 냈다" || ok "이 스크립트를 실행한 worktree 는 다른 세션의 일로 내지 않는다"
grep -E 'feat/b' "$T/out" | grep -q '번호 없음' && ok "번호가 없는 worktree 브랜치를 이름 그대로 낸다" \
  || bad "번호가 없는 worktree 브랜치(feat/b)가 출력에 없다"
grep -q 'feat/self' "$T/out" && bad "이 세션 자신의 브랜치(feat/self)를 다른 worktree 로 냈다" || ok "이 세션 자신의 브랜치는 worktree 목록에 없다"

# 받은 수가 한도에 닿으면 잘렸을 수 있다 — 잘린 목록으로 고르지 않게 실패한다
STUB_ISSUES=100000 run
rc=$(cat "$T/rc")
[ "$rc" != 0 ] && grep -q '^!!' "$T/out" && ok "열린 이슈 수가 한도에 닿으면 그 사실을 내고 실패한다" \
  || bad "열린 이슈 수가 한도에 닿았는데 rc=$rc: $(head -1 "$T/out")"

for what in 'issue list' 'pr list'; do
  STUB_FAIL="$what" run
  rc=$(cat "$T/rc")
  [ "$rc" != 0 ] && grep -q '^!!' "$T/out" && ok "gh $what 이 실패하면 그 사실을 내고 실패한다" \
    || bad "gh $what 이 실패했는데 rc=$rc: $(head -1 "$T/out")"
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
