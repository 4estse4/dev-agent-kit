#!/usr/bin/env bash
# merge-pr 3절이 머지 뒤에 닫을 이슈를 이 PR 의 모든 사람 계정 코멘트에서 고르는가(이슈 #55 의 C).
#
# 이 테스트가 있는 이유: 머지 뒤에 닫을 이슈를 `dev-log` 는 PR 코멘트 전체에서, `merge-pr` 은 2절이
# 읽는 마지막 라운드 코멘트 뒤의 코멘트에서만 골랐다. 1라운드 뒤에 「이 PR 로 #X 를 끝낸다」고
# 정하고 마지막 라운드 뒤에 다시 정하지 않으면, `dev-log` 는 계획에서 #X 를 지우고 `merge-pr` 은 #X 를
# 닫지 않았다.
#
# 스킬 글에서 3절의 읽는 명령(2절의 것과 달리 `$i` 앵커가 없는 식)을 꺼내 PR 코멘트 모양의 JSON 에
# 실행한다. 보는 것:
#   · 앞 라운드 뒤의 사람 계정 코멘트도 읽는다
#   · 마지막 라운드 뒤의 사람 계정 코멘트도 읽는다
#   · 봇이 올린 라운드 코멘트 · 결정 코멘트 · 옛 제목 코멘트와 쓰기 권한 없는 사람의 코멘트는 읽지 않는다
#   · 봇 설정이 없어 라운드 코멘트가 사람 계정이면 아무것도 읽지 않는다(킷은 봇과 함께 쓴다)
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT/claude-code/skills/merge-pr/SKILL.md" <<'PY'
import json, re, subprocess, sys
sk = open(sys.argv[1], encoding='utf-8').read()
fail = 0


def ok(m):
    print(f'  ✓ {m}')


def bad(m):
    global fail
    print(f'  ✗ {m}')
    fail = 1


fs = [f for f in re.findall(r"--jq '([^']*)'", sk) if '$bot' in f and '$i' not in f]
if len(fs) != 1:
    bad(f'3절에서 모든 사람 계정 코멘트를 읽는 명령(2절의 `$i` 앵커 없이 `$bot` 으로 고르는 식)이 하나여야 하는데 {len(fs)}개다')
    sys.exit(1)

bodies = [
    '## 리뷰 1라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n리뷰한 head: aaaa\n',
    '- 1라운드 코멘트: 제안대로 고치고 2라운드\n- 끝낼 이슈: #77 도 이 PR 로 끝낸다\n',
    '## 리뷰 2라운드 — 셀프 ***`Approve`*** · 콜드 ***`Approve`***\n\n리뷰한 head: bbbb\n',
    '- 2라운드 코멘트: 머지한다\n',
    '## 머지 결정\n\n- 사람이 머지를 결정했다\n',
]
OLD = '### 1라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "#55 도 닫자"\n  → 닫는다\n'   # 옛 제목 코멘트


def run(comments):
    r = subprocess.run(['jq', '-r', fs[0]], input=json.dumps({'comments': [
        {'body': b, 'author': {'login': who}, 'authorAssociation': assoc} for b, who, assoc in comments]}),
        capture_output=True, text=True)
    if r.returncode != 0:
        bad('읽는 명령의 jq 식이 실패했다: ' + r.stderr.strip()[:80])
        sys.exit(1)
    return r.stdout


# 라운드 코멘트 · 결정 코멘트는 봇이 올리고, 사람의 결정은 창에서 고른 보기로 만든 사람 계정 코멘트나
# 사람이 PR 웹에서 쓴 코멘트다
BOT, ME = ('helper-bot', 'NONE'), ('me', 'OWNER')
out = run([(bodies[0], *BOT), (bodies[1], *ME), (bodies[2], *BOT), (bodies[3], *ME),
           ('#88 도 이 PR 로 끝내', *ME), ('좋아 보인다. #99 도 닫자', 'someone', 'CONTRIBUTOR'),
           (OLD, *BOT), (bodies[4], *BOT)])
for name, cond in [('앞 라운드 뒤의 사람 계정 코멘트도 읽는다(#77)', '#77' in out),
                   ('마지막 라운드 뒤의 사람 계정 코멘트도 읽는다', '머지한다' in out),
                   ('사람이 웹에서 쓴 코멘트도 읽는다(#88)', '#88' in out),
                   ('라운드 코멘트는 읽지 않는다', '## 리뷰 ' not in out),
                   ('봇의 결정 코멘트는 읽지 않는다', '## 머지 결정' not in out),
                   ('봇이 올린 옛 제목 코멘트는 읽지 않는다(#55)', '#55' not in out),
                   ('쓰기 권한 없는 사람의 코멘트는 읽지 않는다(#99)', '#99' not in out)]:
    ok(name) if cond else bad(name)

# 봇 설정이 없으면 세션과 사람이 한 계정(me)이라 라운드 코멘트도 사람 계정이다. 킷은 봇과 함께 쓰므로
# 아무것도 읽지 않는다 — 옛 제목 코멘트도, 동료의 코멘트도
out = run([(b, *ME) for b in bodies] + [(OLD, *ME), ('#66 도 닫자', 'mate', 'COLLABORATOR')])
for name, cond in [('봇 설정이 없으면 옛 제목 코멘트도 읽지 않는다(#55)', '#55' not in out),
                   ('봇 설정이 없으면 동료의 코멘트도 읽지 않는다(#66)', '#66' not in out),
                   ('봇 설정이 없으면 아무것도 읽지 않는다', out.strip() == '')]:
    ok(name) if cond else bad(name)
sys.exit(fail)
PY
