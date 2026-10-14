#!/usr/bin/env bash
# 설치되는 추적표 템플릿 머리가 적는 `trace.sh` 의 동작이 실제 동작과 같은가.
#
# 이 테스트가 있는 이유: `common/templates/traceability.md` 머리는 `trace.sh` 가 확인하는 것과 통과시키는 것을 나열한다.
# SPEC 템플릿(ID 형식)과 템플릿 `CLAUDE.md`(「요구 추적」)도 그 동작에 기대어 적는다. `trace.sh` 가 바뀌면 그 문장들이
# 알림 없이 거짓이 되므로, 나열한 경우마다 `trace.sh` 를 실행한다. 이 테스트가 실패하면 `trace.sh` 를 고친 PR 이 그
# 문장들과 이 테스트를 함께 고친다.
#
# 보는 것:
#   · 막는 것: ID 가 있는 요구에 행이 없다 · SPEC 에 없는 ID 의 행 · 상태 칸이 넷 밖 · `구현됨` 행에 적힌 구현 경로나
#     테스트 경로가 없다
#   · 통과시키는 것: 같은 ID 의 행 둘 · `구현됨` 행의 구현 · 테스트 칸이 `—` 이거나 비었다 · ID 없이 적힌 요구 ·
#     영역이 영어 대문자로 시작하지 않는 ID(행이 없어도)
#   · 설치되는 템플릿 그대로의 SPEC 과 추적표는 통과한다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
TRACE="$KIT/common/gate/trace.sh"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
n=0
run() { # $1=SPEC 본문 $2=추적표 행 — trace.sh 의 종료 코드를 $rc 에, 출력을 $out 에 둔다
  n=$((n + 1)); d="$T/r$n"
  git init -q -b main "$d"; mkdir -p "$d/docs"; touch "$d/a.go" "$d/a_test.go"
  printf '# SPEC\n\n%b\n' "$1" > "$d/docs/SPEC.md"
  printf '| 요구 | 제목 | 구현 | 테스트 | 상태 | 비고 |\n| --- | --- | --- | --- | --- | --- |\n%b' "$2" > "$d/docs/traceability.md"
  out=$(cd "$d" && bash "$TRACE" 2>&1); rc=$?
}
blocks() { # $1=설명 $2=SPEC 본문 $3=추적표 행
  run "$2" "$3"
  if [ "$rc" -ne 0 ]; then ok "$1"; else bad "$1 — 막아야 한다: [$out]"; fi
}
passes() { # $1=설명 $2=SPEC 본문 $3=추적표 행
  run "$2" "$3"
  if [ "$rc" -eq 0 ]; then ok "$1"; else bad "$1 — 통과해야 한다: [$out]"; fi
}

echo "── 막는 것"
blocks "ID 가 있는 요구에 행이 없으면 막는다" '- R-AB-01 요구' ''
blocks "SPEC 에 없는 ID 의 행을 막는다" '- R-AB-01 요구' \
  '| R-AB-01 | 요구 | — | — | 미구현 | |\n| R-AB-02 | 없는 요구 | — | — | 미구현 | |\n'
blocks "상태 칸이 넷 밖이면 막는다" '- R-AB-01 요구' '| R-AB-01 | 요구 | — | — | 끝남 | |\n'
blocks "구현됨 행에 적힌 구현 경로가 없으면 막는다" '- R-AB-01 요구' '| R-AB-01 | 요구 | `b.go` | `a_test.go` | 구현됨 | |\n'
blocks "구현됨 행에 적힌 테스트 경로가 없으면 막는다" '- R-AB-01 요구' '| R-AB-01 | 요구 | `a.go` | `b_test.go` | 구현됨 | |\n'

echo "── 통과시키는 것"
passes "같은 ID 의 행 둘은 통과한다" '- R-AB-01 요구' \
  '| R-AB-01 | 요구 | `a.go` | `a_test.go` | 구현됨 | |\n| R-AB-01 | 요구 | — | — | 미구현 | 둘째 행 |\n'
passes "구현됨 행의 구현 · 테스트 칸이 — 여도 통과한다" '- R-AB-01 요구' '| R-AB-01 | 요구 | — | — | 구현됨 | |\n'
passes "구현됨 행의 구현 · 테스트 칸이 비어도 통과한다" '- R-AB-01 요구' '| R-AB-01 | 요구 |  |  | 구현됨 | |\n'
passes "ID 없이 적힌 요구는 요구로 읽지 않는다" '- 로그인 실패를 다섯 번 하면 계정을 잠근다' ''
passes "영역이 영어 대문자로 시작하지 않는 ID 는 요구로 읽지 않는다" '- R-auth-01 요구\n- R-인증-01 요구' ''

echo "── 설치되는 템플릿"
d="$T/tpl"; git init -q -b main "$d"; mkdir -p "$d/docs"
cp "$KIT/common/templates/SPEC.md" "$d/docs/SPEC.md"
cp "$KIT/common/templates/traceability.md" "$d/docs/traceability.md"
out=$(cd "$d" && bash "$TRACE" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then ok "템플릿 그대로의 SPEC 과 추적표는 통과한다"
else bad "템플릿 그대로의 SPEC 과 추적표가 통과해야 한다: [$out]"; fi

exit $fail
