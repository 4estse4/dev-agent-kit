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

if [ "$MODE" = staged ]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACM)
else
  FILES=$(git diff --name-only --diff-filter=ACM "$RANGE" 2>/dev/null)
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
  DIFF=$(git diff --cached -U0)
else
  DIFF=$(git diff -U0 "$RANGE" 2>/dev/null)
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
echo "시크릿 스캔 실패 — 커밋을 중단합니다." >&2
[ -n "$BAD_NAMES" ] && { echo "" >&2; echo "금지된 파일:" >&2; printf '%s' "$BAD_NAMES" >&2; }
if [ -n "$BAD_CONTENT" ]; then
  echo "" >&2; echo "시크릿 패턴이 포함된 추가 줄:" >&2
  printf '%s\n' "$BAD_CONTENT" | sed 's/^/  /' >&2
fi
cat >&2 <<'MSG'

조치:
  · 실제 시크릿이면 파일을 스테이지에서 빼고 .gitignore에 넣는다.
  · 테스트용 더미면 같은 줄 끝에 secret-ok 주석을 단다.
MSG
exit 1
