#!/usr/bin/env bash
# 두 리뷰와 merge-pr 2절이 라운드 코멘트 뒤에서 사람의 결정을 고르는가.
#
# 세 자리(`cold-reviewer` 에이전트 · `self-review` 스킬의 주입 · `merge-pr` 2절)가 마지막 라운드
# 코멘트(`## 리뷰 `)를 앵커로 삼고, 그 뒤의 코멘트에서 사람의 결정을 고른다. 고르는 규칙은 둘이다.
#   · 3.5 코멘트 제목(`### N라운드 코멘트를 읽고 사람이 정한 것`)이 맞는 코멘트
#   · 라운드 코멘트와 글쓴이가 다르고 `authorAssociation` 이 OWNER · MEMBER · COLLABORATOR 인 코멘트.
#     봇 설정이 있으면 라운드 코멘트는 봇이 올리고, 사람은 PR 웹에서 제목 없이 결정을 쓸 수 있다
# 위치로만 고르면 봇의 결정 코멘트와 제3자 코멘트가 사람의 답과 같은 자리로 실린다.
#
# 세 파일의 글에서 jq 식을 꺼내 PR 코멘트 모양의 JSON 에 실행한다. `gh pr view --json comments` 는
# 코멘트마다 `author.login` 과 `authorAssociation` 을 준다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1
python3 - <<'PY'
import json, re, subprocess, sys

HEAD = '라운드 코멘트를 읽고 사람이 정한 것'
SITES = ['claude-code/agents/cold-reviewer.md', 'claude-code/skills/self-review/SKILL.md',
         'claude-code/skills/merge-pr/SKILL.md']
fail = 0


def ok(m):
    print(f'  ✓ {m}')


def bad(m):
    global fail
    print(f'  ✗ {m}')
    fail = 1


BOT, ME, OTHER = ('kit-bot', 'NONE'), ('me', 'OWNER'), ('someone', 'CONTRIBUTOR')
ROUND = '## 리뷰 1라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n리뷰한 head: aaaa\n'
ANS = '### 1라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "고치고 2라운드"\n  → 고친다\n'
WEB = '리뷰 봤다. 필수만 고치고 한 라운드 더'
DEC = '## 머지 결정\n\n- 사람이 머지를 결정했다\n'
THIRD = '좋아 보인다. 나도 써 보고 싶다'
cases = [
    ('봇 설정 없음 · 3.5 코멘트를 고른다', [(ROUND, ME), (ANS, ME)], ['고치고 2라운드'], []),
    ('봇 설정 없음 · 같은 계정의 제목 없는 코멘트는 고르지 않는다', [(ROUND, ME), (DEC, ME)], [], ['머지 결정']),
    ('봇 설정 · 사람이 PR 웹에서 쓴 코멘트를 고른다', [(ROUND, BOT), (WEB, ME)], ['필수만 고치고'], []),
    ('봇 설정 · 사람 계정의 3.5 코멘트를 고른다', [(ROUND, BOT), (ANS, ME)], ['고치고 2라운드'], []),
    ('봇 설정 · 봇의 결정 코멘트는 고르지 않는다', [(ROUND, BOT), (DEC, BOT)], [], ['머지 결정']),
    ('봇 설정 · 쓰기 권한 없는 사람의 코멘트는 고르지 않는다', [(ROUND, BOT), (THIRD, OTHER)], [], ['써 보고']),
    ('봇 설정 · 앵커 앞의 사람 코멘트는 고르지 않는다', [(WEB, ME), (ROUND, BOT)], [], ['필수만 고치고']),
]

for path in SITES:
    text = open(path, encoding='utf-8').read()
    fs = [f for f in re.findall(r"(?:--jq |_q=)'([^']*)'", text) if HEAD in f and '$i' in f]
    if len(fs) != 1:
        bad(f'{path} 에서 라운드 코멘트 뒤의 사람의 결정을 고르는 식이 하나여야 하는데 {len(fs)}개다')
        continue
    for name, comments, want, never in cases:
        data = {'comments': [{'body': b, 'author': {'login': who}, 'authorAssociation': assoc}
                             for b, (who, assoc) in comments]}
        r = subprocess.run(['jq', '-r', fs[0]], input=json.dumps(data), capture_output=True, text=True)
        if r.returncode != 0:
            bad(f'{path} · {name} — jq 실패: {r.stderr.strip()[:80]}')
            continue
        miss = [w for w in want if w not in r.stdout] + [n for n in never if n in r.stdout]
        if miss:
            bad(f'{path} · {name} — 「{miss[0]}」 때문에 틀렸다: {r.stdout.strip()[:120]}')
        else:
            ok(f'{path.split("/")[-2]} · {name}')

if not fail:
    print('  ✓ 세 자리가 라운드 코멘트 뒤에서 사람의 결정만 고른다')
sys.exit(fail)
PY
