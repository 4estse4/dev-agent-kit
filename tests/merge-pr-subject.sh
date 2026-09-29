#!/usr/bin/env bash
# merge-pr 3절이 스쿼시 제목을 「PR 제목 (#N)」으로 전달하는가(이슈 #68).
#
# 이 테스트가 있는 이유: 머지 명령이 `--subject` 를 전달하지 않아, 레포 설정의 기본값
# `COMMIT_OR_PR_TITLE` 이 커밋이 하나인 PR 에서 그 커밋의 제목을 스쿼시 제목으로 썼다. PR 제목에 둔
# 규약이 알림 없이 빠졌다. `--subject` 로 전달하면 GitHub 은 그 글자를 그대로 쓰고 `(#N)` 을 붙이지 않아서
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
             ('fix: keep \\$PATH, \\" and \\\\ as typed', 8),
             # ASCII 구두점을 모두 든 제목. 셸이 해석하지 않는 글자(`!` 같은 것)를 집합에 더하면 그 앞에 `\` 가
             # 남는다. 시험 제목에 없는 글자는 집합에 더해도 통과했다
             ('chore: every mark !"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~ ends here', 9)]
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

# 머지 명령은 둘이다 — 바로 머지하는 것과 auto-merge 를 켜는 것(3절 「봇 설정이 있을 때」, 번호 목록 안이라
# 더 들여썼다). 한때 4칸 들여쓴 줄만 찾아 auto-merge 명령을 보지 않았다.
m = re.findall(r'^ +gh pr merge <N> .*$', sk, re.M)
if len(m) != 2:
    bad(f'3절의 머지 명령(`gh pr merge <N>`)이 둘(바로 머지 · auto-merge)이어야 하는데 {len(m)}개다')
elif all('--subject "' in x for x in m):
    ok('3절의 머지 명령 둘이 --subject 를 큰따옴표로 전달한다')
else:
    bad('3절의 머지 명령이 --subject 를 전달하지 않는다 — 커밋이 하나인 PR 은 그 커밋의 제목이 스쿼시 제목이 된다')

# 스쿼시 본문에 `Closes #<번호>` 줄을 넣으면(봇 설정이 있을 때 본문 밖에서 끝낸 이슈) 그 줄의 자리에 따라
# 트레일러가 사라진다. 트레일러 문단에 붙이면 git 이 그 문단을 트레일러로 읽지 못한다. 명령 틀이 그 줄의
# 자리를 보이고, 그 자리에 둬도 트레일러가 읽히는지 본다.
blocks = re.findall(r'^( +)gh pr merge <N> [^\n]*?--body "(.*?)"$', sk, re.M | re.S)
for ind, body in blocks:
    lines = body.split('\n')
    lines = [lines[0]] + [l[len(ind):] if l.startswith(ind) else l for l in lines[1:]]
    text = '\n'.join(lines)
    if not re.search(r'^Closes #', text, re.M):
        bad('머지 명령 틀에 `Closes #<번호>` 줄의 자리가 없다 — 세션이 트레일러 뒤에 붙일 수 있다')
        continue
    msg = 's\n\n' + text.replace('<브랜치 커밋의 트레일러 줄>', 'Co-Authored-By: A <a@b.c>')
    msg = re.sub(r'<[^>\n]*>', 'x', msg) + '\n'
    r = subprocess.run(['git', 'interpret-trailers', '--parse'], input=msg, capture_output=True, text=True)
    if 'Co-Authored-By: A' in r.stdout:
        ok(f'머지 명령 틀({len(ind)}칸 들여씀)의 `Closes` 줄 자리에서도 트레일러가 읽힌다')
    else:
        bad(f'머지 명령 틀({len(ind)}칸 들여씀)대로 쓰면 트레일러가 읽히지 않는다')
if len(blocks) != len(m):
    bad(f'--body 를 가진 머지 명령 틀이 {len(blocks)}개다 — 머지 명령은 {len(m)}개다')
sys.exit(fail)
PY
