#!/usr/bin/env bash
# GitHub 브랜치 보호 설정. 로컬 훅은 --no-verify 로 우회되므로
# 우회 불가능한 강제는 여기에만 존재한다.
#
#   protect-branch.sh [브랜치=main] [체크이름...]
set -uo pipefail
BRANCH="${1:-main}"; shift || true
CHECKS=("$@"); [ ${#CHECKS[@]} -eq 0 ] && CHECKS=(gate security trace)

command -v gh >/dev/null || { echo "protect: gh CLI 가 필요합니다" >&2; exit 1; }
slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
  echo "protect: 원격 GitHub 레포를 찾을 수 없습니다" >&2; exit 1; }

contexts=$(printf '"%s",' "${CHECKS[@]}"); contexts="[${contexts%,}]"

body=$(cat <<JSON
{
  "required_status_checks": { "strict": true, "contexts": $contexts },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON
)

out=$(printf '%s' "$body" | gh api -X PUT "repos/$slug/branches/$BRANCH/protection" --input - 2>&1)
rc=$?
if [ $rc -eq 0 ]; then
  echo "protect ✓ $slug@$BRANCH — 필수 체크: ${CHECKS[*]} · force push·삭제 금지 · PR 필수"
  exit 0
fi

echo "protect ✗ 설정 실패" >&2
printf '%s\n' "$out" | head -5 >&2
if printf '%s' "$out" | grep -qi 'upgrade\|not available\|403'; then
  cat >&2 <<'MSG'

private 레포의 브랜치 보호는 유료 플랜이 필요할 수 있습니다.
대안(약한 순서):
  1. 제출·공개 시점에 레포를 public 으로 바꾸면 무료로 보호가 켜진다.
  2. 그때까지는 로컬 훅(.git/hooks) + CI 가시성으로 운영하고,
     "브랜치 보호 없음"을 알려진 갭으로 문서에 기록한다 — 숨기지 않는다.
MSG
fi
exit 1
