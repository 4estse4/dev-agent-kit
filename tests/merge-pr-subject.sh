#!/usr/bin/env bash
# merge-pr 3절이 스쿼시 제목을 「PR 제목 (#N)」으로 전달하는가(이슈 #68).
#
# 이 테스트가 있는 이유: 머지 명령이 `--subject` 를 전달하지 않아, 레포 설정의 기본값
# `COMMIT_OR_PR_TITLE` 이 커밋이 하나인 PR 에서 그 커밋의 제목을 스쿼시 제목으로 썼다. PR 제목에 둔
# 규약이 조용히 빠졌다. `--subject` 로 전달하면 GitHub 은 그 글자를 그대로 쓰고 `(#N)` 을 붙이지 않아서
# 조회가 붙인다.
#
# 스킬 글에서 식을 꺼내 실행한다. 보는 것:
#   · 제목 조회(`gh pr view <N> --json title,number --jq '…'`)의 jq 식을 JSON 에 실행하고, 그 출력을
#     머지 명령처럼 큰따옴표 인자로 셸에 전달하면 「PR 제목 (#N)」이 그대로 나온다. 태그 · 작은따옴표 ·
#     셸이 해석하는 글자(`"` · `$` · 백틱 · `\`)가 든 제목으로 본다
#   · 3절의 머지 명령 줄이 `--subject` 를 큰따옴표로 전달한다
#   · 「닫히는 이슈 줄」의 제목 조회와 머지 명령 앞의 제목 조회가 같은 식이다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT/claude-code/skills/merge-pr/SKILL.md" <<'PY'
import re, subprocess, sys, json
sk = open(sys.argv[1], encoding='utf-8').read()
fail = 0


def ok(m):
    print(f'  ✓ {m}')


def bad(m):
    global fail
    print(f'  ✗ {m}')
    fail = 1


qs = re.findall(r"^    gh pr view <N> --json title,number --jq '(.*)'$", sk, re.M)
if len(qs) < 2:
    bad(f"제목 조회(`gh pr view <N> --json title,number --jq '…'`)가 둘이어야 하는데 {len(qs)}개다 — 「닫히는 이슈 줄」과 머지 명령 앞")
elif len(set(qs)) != 1:
    bad('「닫히는 이슈 줄」의 제목 조회와 머지 명령 앞의 제목 조회가 다른 식이다')
else:
    ok(f'제목 조회가 {len(qs)}곳에 같은 식으로 있다')

if qs:
    cases = [('[P4] docs: point the rule', 29), ("fix(lint): keep revive's default rules", 139),
             ('fix: handle `nil` and $HOME "x" \\ end $(echo hi)', 7),
             # `\` 가 셸이 해석하는 글자 앞에 오면 `\` 도 막아야 한다. 뒤가 공백인 `\` 는 큰따옴표 안에서도
             # 그대로라, 그것만으로는 `\` 를 빠뜨린 식이 통과했다
             ('fix: keep \\$PATH, \\" and \\\\ as typed', 8)]
    for title, n in cases:
        want = f'{title} (#{n})'
        r = subprocess.run(['jq', '-r', qs[0]], input=json.dumps({'title': title, 'number': n}),
                           capture_output=True, text=True)
        if r.returncode != 0:
            bad(f'제목 조회의 jq 식이 실패했다: {r.stderr.strip()[:80]}')
            continue
        out = r.stdout.rstrip('\n')
        back = subprocess.run(['bash', '-c', 'printf %s "' + out + '"'], capture_output=True, text=True).stdout
        if back == want:
            ok(f'큰따옴표 인자로 전달해도 제목 그대로다: {want}')
        else:
            bad(f'큰따옴표 인자로 전달하면 제목이 달라진다: {want!r} → {back!r}')

m = re.findall(r'^    gh pr merge <N> .*$', sk, re.M)
if not m:
    bad('3절의 머지 명령(`    gh pr merge <N>`)을 못 찾았다')
elif all('--subject "' in x for x in m):
    ok('3절의 머지 명령이 --subject 를 큰따옴표로 전달한다')
else:
    bad('3절의 머지 명령이 --subject 를 전달하지 않는다 — 커밋이 하나인 PR 은 그 커밋의 제목이 스쿼시 제목이 된다')
sys.exit(fail)
PY
