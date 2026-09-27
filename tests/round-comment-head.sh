#!/usr/bin/env bash
# open-pr 의 두 셈이 라운드 코멘트의 head 를 `리뷰한 head: ` 줄에서 읽는가(이슈 #55 의 B).
#
# 이 테스트가 있는 이유: 3.4 의 게시 전 확인(같은 head 의 라운드 코멘트가 이미 있나)과 3.6 의 다섯째
# 단계의 셈(그 라운드 코멘트 뒤에 3.5 의 코멘트가 올라갔나)이 라운드 코멘트의 셋째 줄을 head 줄로
# 읽었다. 템플릿의 줄 순서가 바뀌어 제목과 head 줄 사이에 줄이 끼면, 두 셈이 head 를 못 찾아 게시 전
# 확인은 같은 head 의 코멘트를 못 세고 3.6 의 셈은 푸시를 막는다.
#
# 스킬 글에서 두 jq 식을 꺼내 PR 코멘트 모양의 JSON 에 실행한다. 보는 것:
#   · 표준 틀 · head 줄 앞에 줄이 낀 코멘트 · 제목 바로 뒤에 head 줄이 온 코멘트에서 head 를 찾는다
#   · 접힌 리뷰 전문 안의 `리뷰한 head:` 가 아니라 맨 위의 것을 쓴다
#   · head 가 다른 코멘트와 3.5 의 코멘트는 세지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT/claude-code/skills/open-pr/SKILL.md" <<'PY'
import json, re, subprocess, sys
sk = open(sys.argv[1], encoding='utf-8').read()
PH = '<3.1 에서 읽은 head>'
fail = 0


def ok(m):
    print(f'  ✓ {m}')


def bad(m):
    global fail
    print(f'  ✗ {m}')
    fail = 1


# `--jq '` 뒤부터 다음 작은따옴표까지가 식이다. head 자리 표시가 든 식만 고른다
filters = [f for f in re.findall(r"--jq '([^']*)'", sk) if PH in f]
same = [f for f in filters if '[$i+1:]' not in f]
after = [f for f in filters if '[$i+1:]' in f]
if len(same) != 1 or len(after) != 1:
    bad(f'head 를 쓰는 식이 게시 전 확인 하나와 3.6 의 셈 하나여야 하는데 {len(same)}개 · {len(after)}개다')
    sys.exit(1)

A, B = 'a' * 40, 'b' * 40
TITLE = '## 리뷰 2라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***'


def details(h):
    return f'<details>\n\n<summary>셀프 리뷰 전문</summary>\n\n## Self review\n\n리뷰한 head: {h}\n\n</details>\n'


def std(h, inner=None):
    return f'{TITLE}\n\n리뷰한 head: {h}\n\n### 1라운드 정리\n\n---\n\n' + details(inner or h)


def inserted(h):
    # 제목과 head 줄 사이에 줄이 하나 더 있다
    return f'{TITLE}\n\n**밀린 결정** 없음.\n\n리뷰한 head: {h}\n\n### 1라운드 정리\n\n' + details(h)


def tight(h):
    # 제목 바로 뒤에 head 줄이 온다
    return f'{TITLE}\n리뷰한 head: {h}\n\n### 1라운드 정리\n\n' + details(h)


ANS = '### 1라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "고친다"\n  → 한 일\n'


BOT, ME, OTHER = ('kit-bot', 'NONE'), ('me', 'OWNER'), ('someone', 'CONTRIBUTOR')


def comment(b):
    """본문만 주면 봇 설정이 없는 레포처럼 모든 코멘트가 사람 계정 하나(me)의 것이다."""
    body, (login, assoc) = (b, ME) if isinstance(b, str) else b
    return {'body': body, 'author': {'login': login}, 'authorAssociation': assoc}


def run(f, bodies, h):
    r = subprocess.run(['jq', f.replace(PH, h)], input=json.dumps({'comments': [comment(b) for b in bodies]}),
                       capture_output=True, text=True)
    if r.returncode != 0:
        return 'jq 실패: ' + r.stderr.strip()[:80]
    return r.stdout.strip()


cases = [
    (same[0], '게시 전 확인 · 표준 틀', [std(A)], A, '1'),
    (same[0], '게시 전 확인 · head 줄 앞에 줄이 낌', [inserted(A)], A, '1'),
    (same[0], '게시 전 확인 · 제목 바로 뒤의 head 줄', [tight(A)], A, '1'),
    (same[0], '게시 전 확인 · 접힌 전문의 head 는 세지 않는다', [std(A, inner=B)], B, '0'),
    (same[0], '게시 전 확인 · 맨 위의 head 를 센다', [std(A, inner=B)], A, '1'),
    (same[0], '게시 전 확인 · head 가 다른 코멘트', [std(B)], A, '0'),
    (same[0], '게시 전 확인 · 3.5 의 코멘트는 세지 않는다', [ANS + '리뷰한 head: ' + A], A, '0'),
    (same[0], '게시 전 확인 · head 줄이 없는 라운드 코멘트', [TITLE + '\n\n### 1라운드 발견\n'], A, '0'),
    (after[0], '3.6 의 셈 · 표준 틀', [std(A), ANS], A, '1'),
    (after[0], '3.6 의 셈 · head 줄 앞에 줄이 낌', [inserted(A), ANS], A, '1'),
    (after[0], '3.6 의 셈 · 제목 바로 뒤의 head 줄', [tight(A), ANS], A, '1'),
    (after[0], '3.6 의 셈 · 접힌 전문의 head 를 앵커로 쓰지 않는다', [std(A, inner=B), ANS], B, '0'),
    (after[0], '3.6 의 셈 · 3.5 의 코멘트가 라운드 코멘트보다 앞', [ANS, std(A)], A, '0'),
    (after[0], '3.6 의 셈 · head 줄이 없는 라운드 코멘트', [TITLE + '\n\n### 1라운드 발견\n', ANS], A, '0'),
    (after[0], '3.6 의 셈 · 봇 설정 없음, 같은 계정의 제목 없는 코멘트', [std(A), '머지 결정\n'], A, '0'),
    (after[0], '3.6 의 셈 · 봇 설정 없음, 동료의 제목 없는 코멘트', [std(A), ('LGTM', ('mate', 'COLLABORATOR'))], A, '0'),
    # 봇 설정이 있으면 라운드 코멘트는 봇이 올리고, 사람은 PR 웹에서 제목 없이 쓸 수 있다
    (after[0], '3.6 의 셈 · 봇의 라운드 코멘트 뒤 사람이 웹에서 쓴 코멘트', [(std(A), BOT), ('고치고 한 라운드 더', ME)], A, '1'),
    (after[0], '3.6 의 셈 · 봇의 라운드 코멘트 뒤 사람 계정의 3.5 코멘트', [(std(A), BOT), (ANS, ME)], A, '1'),
    (after[0], '3.6 의 셈 · 봇의 라운드 코멘트 뒤 봇의 다른 코멘트', [(std(A), BOT), ('## 머지 결정\n', BOT)], A, '0'),
    (after[0], '3.6 의 셈 · 봇의 라운드 코멘트 뒤 쓰기 권한 없는 사람의 코멘트', [(std(A), BOT), ('좋아 보인다', OTHER)], A, '0'),
]
for f, name, bodies, h, want in cases:
    got = run(f, bodies, h)
    if got == want:
        ok(f'{name} ({got})')
    else:
        bad(f'{name} — 기대 {want}, 실제 {got}')
sys.exit(fail)
PY
