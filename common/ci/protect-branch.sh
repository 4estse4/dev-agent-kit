#!/usr/bin/env bash
# GitHub 브랜치 보호 설정. 로컬 훅은 --no-verify 로 우회되므로
# 우회 불가능한 강제는 여기에만 존재한다.
#
#   protect-branch.sh [브랜치=main] [체크이름...]
#
# 레포에 봇 설정(`.claude/bot.json`)이 있으면 머지에 사람의 Approve 하나를 요구하고, 새 커밋이 오면
# 이전 승인을 없던 것으로 하고, 마지막 푸시는 푸시한 사람이 아닌 사람이 승인하게 한다. 봇 설정이 있으면
# PR 작성자와 푸시한 계정이 봇이라 사람이 승인할 수 있다. 없으면 PR 작성자가 사람 자신이라 자기 PR 을
# 승인할 수 없어(GitHub: "Pull request authors cannot approve their own pull requests.") 승인을
# 요구하지 않는다 — 요구하면 모든 머지가 막힌다.
#
# 봇 설정이 있으면 레포 설정 「Allow auto-merge」 · 「Automatically delete head branches」도 켠다. 세션은
# 결정 코멘트를 올리고 auto-merge 를 켠 뒤 Approve 를 요청하고(`merge-pr` 3절), 사람이 Approve 하면
# GitHub 이 머지하고 head 브랜치를 지운다.
set -uo pipefail
BRANCH="${1:-main}"; shift || true
CHECKS=("$@"); [ ${#CHECKS[@]} -eq 0 ] && CHECKS=(gate security trace)

command -v gh >/dev/null || { echo "protect: gh CLI 가 필요합니다" >&2; exit 1; }
slug=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
  echo "protect: 원격 GitHub 레포를 찾을 수 없습니다" >&2; exit 1; }

contexts=$(printf '"%s",' "${CHECKS[@]}"); contexts="[${contexts%,}]"
top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ] && [ -f "$top/.claude/bot.json" ]; then approvals=1 last_push=true
else approvals=0 last_push=false; fi

body=$(cat <<JSON
{
  "required_status_checks": { "strict": true, "contexts": $contexts },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": $approvals,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": $last_push
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
  echo "protect ✓ $slug@$BRANCH — 필수 체크: ${CHECKS[*]} · force push·삭제 금지 · PR 필수 · 필요 승인 $approvals"
  [ "$approvals" = 1 ] || exit 0
  out=$(printf '{"allow_auto_merge": true, "delete_branch_on_merge": true}' \
    | gh api -X PATCH "repos/$slug" --input - 2>&1)
  if [ $? -eq 0 ]; then
    echo "protect ✓ $slug — auto-merge 허용 · 머지 뒤 head 브랜치 삭제"
    exit 0
  fi
  echo "protect ✗ 레포 설정(auto-merge 허용 · 머지 뒤 head 브랜치 삭제) 실패" >&2
  printf '%s\n' "$out" | head -5 >&2
  exit 1
fi

echo "protect ✗ 설정 실패" >&2
printf '%s\n' "$out" | head -5 >&2
if printf '%s' "$out" | grep -qi 'upgrade\|not available\|403'; then
  cat >&2 <<'MSG'

private 레포의 브랜치 보호는 유료 플랜이 필요할 수 있습니다.
대안(강한 것부터):
  1. 레포를 public 으로 바꿀 수 있으면, 바꾼 뒤 킷의 install.sh <경로> --protect 로 보호 설정을 다시 실행하세요. public 레포는 브랜치 보호가 무료입니다.
  2. 그럴 수 없으면 로컬 훅(.ai-kit/git-hooks) + CI 결과로 운영하고,
     "브랜치 보호 없음"을 알려진 한계로 문서에 기록합니다 — 숨기지 않습니다.
MSG
fi
exit 1
