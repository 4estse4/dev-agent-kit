#!/usr/bin/env bash
# 시크릿 스캔. staged 내용(기본) 또는 지정 ref 범위를 검사한다.
# 오탐을 줄이려 "높은 확신 패턴"만 본다 — 엔트로피 추정은 하지 않는다.
# 정당한 테스트 픽스처는 같은 줄에 secret-ok 마커를 달아 면제한다.
#
#   secrets.sh              staged 내용 검사 (pre-commit)
#   secrets.sh --range A..B 커밋 범위 검사 (pre-push / CI)
set -uo pipefail

MODE="staged"; RANGE=""
[ "${1:-}" = "--range" ] && { MODE="range"; RANGE="${2:-}"; }

# ── 1. 파일명으로 금지 ──────────────────────────────────────────
FORBIDDEN_NAMES='(^|/)(\.env(\..*)?|.*-key\.json|.*\.pem|.*\.p12|.*\.pfx|id_rsa|id_ed25519|credentials\.json|service-account.*\.json)$'
ALLOWED_NAMES='(\.env\.example|\.env\.sample|\.env\.template)$'

# git 실패를 삼키면 DIFF 가 비어 "매치 없음 = 통과" 가 된다.
# 범위 해석 실패(shallow clone·사라진 SHA·잘못된 인자)는 검사 불능이지 통과가 아니다.
if [ "$MODE" = staged ]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACM) || {
    echo "시크릿 스캔 오류: staged 목록을 읽지 못했습니다." >&2; exit 2; }
else
  # `git diff A..B` 는 두 끝점의 차이만 본다 — 범위 안에서 추가됐다가 지워진 파일은
  # 보이지 않는다. 시크릿을 커밋했다가 다음 커밋에서 지우는 것은 사람이 "고쳤다" 고
  # 믿는 가장 흔한 복구 동작이고, 그때 원격에는 그대로 남는다(재현함).
  # 그래서 커밋 단위로 훑는다.
  # --diff-merges=first-parent: git log 는 기본적으로 머지 커밋의 diff 를 내지 않는다.
  # 충돌 해소 중에 써넣은 시크릿이 그래서 통째로 안 보인다(재현함).
  FILES=$(git log --name-only --diff-filter=ACM --diff-merges=first-parent --pretty=format: "$RANGE" | sort -u | sed '/^$/d') || {
    echo "시크릿 스캔 오류: 범위 '$RANGE' 를 해석하지 못했습니다 — 검사를 신뢰할 수 없어 중단합니다." >&2
    exit 2; }
fi

BAD_NAMES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s' "$f" | grep -qE "$ALLOWED_NAMES" && continue
  printf '%s' "$f" | grep -qE "$FORBIDDEN_NAMES" && BAD_NAMES="${BAD_NAMES}  ${f}"$'\n'
done <<< "$FILES"

# ── 2. 내용으로 금지 ────────────────────────────────────────────
# 패턴을 변수로 조립해 이 스크립트 자신이 스캔에 걸리지 않게 한다.
P_PRIVKEY='-----BEGIN [A-Z ]*PRIVATE KEY-----'
P_JSONKEY='"'"private_key"'"[[:space:]]*:[[:space:]]*"'
P_AWS='AKIA[0-9A-Z]{16}'
P_GH='gh[pousr]_[A-Za-z0-9]{30,}'
P_SLACK='xox[baprs]-[A-Za-z0-9-]{10,}'
P_GCP='AIza[0-9A-Za-z_-]{35}'
P_OPENAI='sk-[A-Za-z0-9_-]{20,}'
PATTERNS="${P_PRIVKEY}|${P_JSONKEY}|${P_AWS}|${P_GH}|${P_SLACK}|${P_GCP}|${P_OPENAI}"

if [ "$MODE" = staged ]; then
  DIFF=$(git diff --cached -U0) || {
    echo "시크릿 스캔 오류: staged diff 를 읽지 못했습니다." >&2; exit 2; }
else
  # 위와 같은 이유로 diff 도 커밋 단위로 본다.
  DIFF=$(git log -p -U0 --diff-merges=first-parent --pretty=format: "$RANGE") || {
    echo "시크릿 스캔 오류: 범위 '$RANGE' diff 를 읽지 못했습니다." >&2; exit 2; }
fi

# 추가된 줄(+)만 본다. secret-ok 마커가 있으면 면제.
# 추가된 줄(+)만 본다. secret-ok 마커가 있으면 면제.
# grep 종료코드: 0=매치, 1=매치없음(정상), >=2=grep 자체 오류.
# 오류를 || true로 삼키면 검사가 고장 난 채 "통과"한다 — 반드시 구분한다.
ADDED=$(printf '%s\n' "$DIFF" | grep -E -- '^\+' | grep -vE -- 'secret-ok')
BAD_CONTENT=$(printf '%s\n' "$ADDED" | grep -nE -- "$PATTERNS")
rc=$?
if [ $rc -ge 2 ]; then
  echo "시크릿 스캔 오류: grep 실패 (exit $rc) — 검사를 신뢰할 수 없어 중단합니다." >&2
  exit 2
fi

if [ -z "$BAD_NAMES" ] && [ -z "$BAD_CONTENT" ]; then
  exit 0
fi

echo "" >&2
if [ "$MODE" = range ]; then
  echo "시크릿 스캔 실패 — 이 범위의 커밋 중 하나가 시크릿을 들여왔습니다." >&2
else
  echo "시크릿 스캔 실패 — 커밋을 중단합니다." >&2
fi
[ -n "$BAD_NAMES" ] && { echo "" >&2; echo "금지된 파일:" >&2; printf '%s' "$BAD_NAMES" >&2; }
if [ -n "$BAD_CONTENT" ]; then
  echo "" >&2; echo "시크릿 패턴이 포함된 추가 줄:" >&2
  printf '%s\n' "$BAD_CONTENT" | sed 's/^/  /' >&2
fi
if [ "$MODE" = range ]; then
  # 범위 모드는 이미 커밋된 것을 본다. 스테이지에서 빼라는 안내는 여기서 통하지 않고,
  # 지금 지워도 히스토리에 남아 계속 걸린다.
  cat >&2 <<'MSG'

조치 — 이미 커밋된 것이라 **지금 지우는 것으로는 해소되지 않습니다.**
  · 실제 시크릿이면: 먼저 그 키를 폐기·재발급하세요. 되돌릴 수 없습니다.
    그 뒤 히스토리에서 지웁니다 — git rebase -i 로 해당 커밋을 고치거나,
    브랜치를 다시 만들어 깨끗한 커밋으로 옮깁니다.
  · 테스트용 더미면: 그 줄 끝에 secret-ok 주석을 달되, **그 커밋 자체를 고쳐야**
    합니다. 뒤 커밋에서 주석만 추가하면 범위 스캔은 계속 실패합니다.
MSG
else
  cat >&2 <<'MSG'

조치:
  · 실제 시크릿이면 파일을 스테이지에서 빼고 .gitignore에 넣는다.
  · 테스트용 더미면 같은 줄 끝에 secret-ok 주석을 단다.
MSG
fi
exit 1
