#!/usr/bin/env bash
# merge-pr 3절이 머지 뒤에 닫을 이슈를 이 PR 의 모든 3.5 코멘트에서 고르는가(이슈 #55 의 C).
#
# 이 테스트가 있는 이유: 머지 뒤에 닫을 이슈를 `dev-log` 는 PR 코멘트 전체에서, `merge-pr` 은 2절이
# 읽는 마지막 라운드 코멘트 뒤의 3.5 코멘트에서만 골랐다. 1라운드 답에서 「이 PR 로 #X 를 끝낸다」고
# 정하고 마지막 답에서 다시 말하지 않으면, `dev-log` 는 계획에서 #X 를 지우고 `merge-pr` 은 #X 를
# 닫지 않았다.
#
# 스킬 글에서 3절의 읽는 명령(2절의 것과 달리 `$i` 앵커가 없는 식)을 꺼내 PR 코멘트 모양의 JSON 에
# 실행한다. 보는 것:
#   · 앞 라운드의 3.5 코멘트도 읽는다
#   · 마지막 라운드 뒤의 3.5 코멘트도 읽는다
#   · 라운드 코멘트와 결정 코멘트는 읽지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT/claude-code/skills/merge-pr/SKILL.md" <<'PY'
import json, re, subprocess, sys
sk = open(sys.argv[1], encoding='utf-8').read()
HEAD = '라운드 코멘트를 읽고 사람이 정한 것'
fail = 0


def ok(m):
    print(f'  ✓ {m}')


def bad(m):
    global fail
    print(f'  ✗ {m}')
    fail = 1


fs = [f for f in re.findall(r"--jq '([^']*)'", sk) if HEAD in f and '$i' not in f]
if len(fs) != 1:
    bad(f'3절에서 모든 3.5 코멘트를 읽는 명령(2절의 `$i` 앵커 없이 제목으로 고르는 식)이 하나여야 하는데 {len(fs)}개다')
    sys.exit(1)

bodies = [
    '## 리뷰 1라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***\n\n리뷰한 head: aaaa\n',
    '### 1라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "#77 도 이 PR 로 끝내자. 고치고 2라운드"\n  → 고쳤다\n',
    '## 리뷰 2라운드 — 셀프 ***`Approve`*** · 콜드 ***`Approve`***\n\n리뷰한 head: bbbb\n',
    '### 2라운드 코멘트를 읽고 사람이 정한 것\n\n- (사람) "머지"\n  → 머지한다\n',
    '## 머지 결정\n\n- 사람이 머지를 결정했다\n',
]
r = subprocess.run(['jq', '-r', fs[0]], input=json.dumps({'comments': [{'body': b} for b in bodies]}),
                   capture_output=True, text=True)
if r.returncode != 0:
    bad('읽는 명령의 jq 식이 실패했다: ' + r.stderr.strip()[:80])
    sys.exit(1)
out = r.stdout
for name, cond in [('앞 라운드의 3.5 코멘트도 읽는다(#77)', '#77' in out),
                   ('마지막 라운드 뒤의 3.5 코멘트도 읽는다', '"머지"' in out),
                   ('라운드 코멘트는 읽지 않는다', '## 리뷰 ' not in out),
                   ('결정 코멘트는 읽지 않는다', '## 머지 결정' not in out)]:
    ok(name) if cond else bad(name)
sys.exit(fail)
PY
