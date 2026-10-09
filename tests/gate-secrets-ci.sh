#!/usr/bin/env bash
# CI 의 시크릿 스캔은 PR 이면 base..head, push 면 그 푸시가 들여온 커밋을 모두 본다.
#
# 이 테스트가 있는 이유: gates.yml 은 main 에 푸시할 때도 실행되는데, 그때 시크릿 스캔이
# `HEAD~1..HEAD` 만 봤다(이슈 #173). 훅을 건너뛰고 커밋 여럿을 한 번에 푸시하면 앞 커밋의 시크릿을
# CI 가 보지 않았다. 로컬 pre-push 는 푸시 범위 전체를 본다.
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 에서 시크릿 스캔 스텝(run 이 `secrets.sh --range` 를
# 부르는 스텝)을 뽑는다. `${{ … }}` 는 식의 글자로 찾아 경우마다 값으로 바꾼다. 식이 `env:` 에 있든
# run 에 있든 같은 테스트가 적용된다. 모르는 식이 있으면 값을 짐작하지 않고 실패한다. 셸은 러너가
# 고르는 대로 고른다 — GitHub 문서의 shell 표에서 shell 을 적지 않은 Linux 스텝은 `bash -e {0}` 이고,
# `shell: bash` 를 적어야 `bash --noprofile --norc -eo pipefail {0}` 이다. pipefail 로 실행하면 스텝에
# 파이프(`secrets.sh … | tee …`)를 더해 러너에서 secrets.sh 가 실패해도 스텝이 통과하는 회귀를 이 테스트가 통과시킨다
# (PR #177 1라운드 콜드 리뷰). 보는 것:
#   · push 는 before..after 의 커밋을 모두 본다. 앞 커밋이 넣고 뒤 커밋이 지운 것도 찾는다
#   · before 가 0 뿐이거나(main 을 처음 푸시) 체크아웃에 없으면(강제 푸시로 옛 커밋이 어느 브랜치에서도
#     닿지 않는다) after 에서 닿는 커밋을 모두 본다
#   · before 가 있는데 after 의 조상이 아니면(강제 푸시) before..after 를 본다
#   · PR 은 base..head 를 본다. synchronize 이벤트에도 before · after 가 있는데, 그것보다 base..head 가 먼저다
#   · 범위 밖(before · base 보다 앞)에만 있는 시크릿으로는 실패하지 않는다 — 늘 전체 히스토리를 보는
#     구현을 막는다
# 시크릿은 `.env` 파일 이름으로 대신한다. 이름만으로 막히므로 내용 패턴을 이 파일에 적지 않는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R0="$T/installed"; mkdir -p "$R0"
git init -q -b main "$R0"
git -C "$R0" config user.email t@example.com; git -C "$R0" config user.name T
git -C "$R0" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R0" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
Y="$R0/.github/workflows/gates.yml"
[ -f "$Y" ] || { echo "  ✗ $Y 가 없다 — 설치 경로가 바뀌었나"; exit 1; }
# 설치본을 커밋해 둔다. 스텝이 `.kit/gate/secrets.sh` 를 체크아웃에서 찾는다. 훅은 끈다 — 이 테스트는
# 훅을 건너뛴 푸시를 흉내 낸다.
git -C "$R0" add -A && git -C "$R0" -c core.hooksPath=/dev/null commit -qm install

python3 -c 'import yaml' 2>/dev/null || { echo "  ✗ python3 의 yaml 모듈이 없다 — gates.yml 에서 스텝을 뽑을 수 없다"; exit 1; }
python3 - "$Y" "$T/step.json" <<'PY' || exit 1
import json, sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
hits = [(j, s) for j, job in doc['jobs'].items() for s in job.get('steps', [])
        if 'secrets.sh --range' in s.get('run', '')]
if len(hits) != 1:
    print(f"  ✗ run 이 secrets.sh --range 를 부르는 스텝이 {len(hits)}개다 — 하나여야 한다")
    sys.exit(1)
job, step = hits[0]
# 스텝 → 잡의 defaults → 워크플로의 defaults 순으로 적힌 shell 이 그 스텝의 셸이다.
shell = (step.get('shell') or ((doc['jobs'][job].get('defaults') or {}).get('run') or {}).get('shell')
         or ((doc.get('defaults') or {}).get('run') or {}).get('shell') or '')
json.dump({'job': job, 'env': step.get('env') or {}, 'run': step['run'], 'shell': shell}, open(sys.argv[2], 'w'))
PY
case "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["shell"])' "$T/step.json")" in
  '')   SHELL_CMD=(bash -e) ;;
  bash) SHELL_CMD=(bash --noprofile --norc -eo pipefail) ;;
  *)    echo "  ✗ 시크릿 스캔 스텝의 shell 이 이 테스트가 다루지 않는 것이다 — 러너와 같은 셸로 실행할 수 없다"; exit 1 ;;
esac

ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

n=0
new_case() { # 설치본을 복제해 그 경우의 레포를 만든다. 훅은 복제되지 않는다
  n=$((n + 1)); C="$T/case$n"
  git clone -q "$R0" "$C"
  git -C "$C" config user.email t@example.com; git -C "$C" config user.name T
}
# `-f` 로 더한다. 전역 gitignore 가 `.env` 를 무시하는 머신에서는 `-f` 없이 `git add` 가 실패해 그 경우의
# 커밋이 만들어지지 않고, 결함이 없어도 이 테스트가 실패했다(PR #177 1라운드 셀프 리뷰).
commit() { # $1=add|rm  $2=파일 → 커밋하고 SHA 를 출력한다
  if [ "$1" = add ]; then echo "$2" > "$C/$2"; git -C "$C" add -f "$2"; else git -C "$C" rm -q "$2"; fi
  git -C "$C" commit -qm "$1 $2" && git -C "$C" rev-parse HEAD
}

# 스텝을 그 경우의 이벤트 값으로 실행한다. $1=기대(fail|pass) $2=설명 $3=이벤트 $4=base $5=head $6=before $7=after
# 체크아웃은 이벤트가 가리키는 커밋이다(push 는 after, PR 은 head).
check() {
  local want="$1" what="$2" out rc
  python3 - "$T/step.json" "$T/step.sh" "$3" "$4" "$5" "$6" "$7" <<'PY' || { bad "$what — 스텝의 식을 바꾸지 못했다"; return; }
import json, re, shlex, sys
step = json.load(open(sys.argv[1]))
event, base, head, before, after = sys.argv[3:8]
val = {
    'github.event_name': event,
    'github.event.pull_request.base.sha': base,
    'github.event.pull_request.head.sha': head,
    'github.event.before': before,
    'github.event.after': after,
    'github.sha': after if event == 'push' else head,
}
def sub(s):
    def one(m):
        e = m.group(1).strip()
        if e not in val:
            print(f"  ✗ 모르는 식이다 — {e}. 값을 짐작하지 않는다")
            sys.exit(1)
        return val[e]
    return re.sub(r'\$\{\{(.*?)\}\}', one, str(s))
lines = [f"export {k}={shlex.quote(sub(v))}" for k, v in step['env'].items()]
open(sys.argv[2], 'w').write('\n'.join(lines + [sub(step['run'])]) + '\n')
PY
  git -C "$C" checkout -q "$( [ "$3" = push ] && echo "$7" || echo "$5" )"
  out=$(cd "$C" && "${SHELL_CMD[@]}" "$T/step.sh" 2>&1); rc=$?
  [ -n "$out" ] || out="(출력 없음)"
  if [ "$want" = fail ]; then
    # 검사 불능(종료코드 2)은 찾은 것이 아니다. 시크릿 스캔이 .env 를 적으며 실패해야 한다.
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qx '  \.env'; then ok "$what → .env 를 적으며 실패한다"
    else bad "$what → rc=$rc, .env 를 적으며 실패해야 한다:"; printf '%s\n' "$out" | tail -6 | cut -c1-120 | sed 's/^/      /'; fi
  else
    if [ "$rc" -eq 0 ]; then ok "$what → 통과"
    else bad "$what → rc=$rc, 통과해야 한다:"; printf '%s\n' "$out" | tail -6 | cut -c1-120 | sed 's/^/      /'; fi
  fi
}

ZERO=0000000000000000000000000000000000000000

new_case
before=$(git -C "$C" rev-parse HEAD); commit add .env >/dev/null; commit rm .env >/dev/null; after=$(commit add a.txt)
check fail "push · 커밋 셋 중 첫 커밋이 .env 를 넣고 둘째가 지운다" push "" "" "$before" "$after"

new_case
commit add .env >/dev/null; before=$(commit rm .env); after=$(commit add a.txt)
check pass "push · .env 가 before 보다 앞 커밋에만 있다" push "" "" "$before" "$after"

new_case
commit add .env >/dev/null; commit rm .env >/dev/null; after=$(commit add a.txt)
check fail "push · before 가 0 뿐(main 을 처음 푸시) · 앞 커밋에 .env" push "" "" "$ZERO" "$after"

new_case
after=$(commit add a.txt)
check pass "push · before 가 0 뿐 · 히스토리에 .env 가 없다" push "" "" "$ZERO" "$after"

new_case
commit add .env >/dev/null; commit rm .env >/dev/null; after=$(commit add a.txt)
check fail "push · before 가 체크아웃에 없다(강제 푸시) · 앞 커밋에 .env" push "" "" "1111111111111111111111111111111111111111" "$after"

# 강제 푸시인데 옛 커밋이 다른 브랜치에 남아 있다. before..after 가 새로 들어온 커밋이다.
new_case
base=$(git -C "$C" rev-parse HEAD); old=$(commit add old.txt); git -C "$C" branch -q old "$old"
git -C "$C" reset -q --hard "$base"; commit add .env >/dev/null; commit rm .env >/dev/null; after=$(commit add a.txt)
check fail "push · before 가 after 의 조상이 아니다(강제 푸시) · 새 커밋 가운데 앞 커밋에 .env" push "" "" "$old" "$after"

new_case
commit add .env >/dev/null; base=$(commit rm .env); old=$(commit add old.txt); git -C "$C" branch -q old "$old"
git -C "$C" reset -q --hard "$base"; after=$(commit add a.txt)
check pass "push · before 가 after 의 조상이 아니다 · .env 는 두 커밋의 공통 조상보다 앞에만 있다" push "" "" "$old" "$after"

# PR 의 synchronize 이벤트에는 before · after 가 있다(앞 head · 새 head). 그것만 보면 PR 의 앞 커밋이 빠진다.
new_case
base=$(git -C "$C" rev-parse HEAD); commit add .env >/dev/null; prev=$(commit rm .env); head=$(commit add a.txt)
check fail "PR · base..head 가운데 커밋에 .env(synchronize 로 before · after 가 있다)" pull_request "$base" "$head" "$prev" "$head"

new_case
commit add .env >/dev/null; base=$(commit rm .env); head=$(commit add a.txt)
check pass "PR · .env 가 base 보다 앞에만 있다" pull_request "$base" "$head" "" ""

rm -rf "$T"
exit $fail
