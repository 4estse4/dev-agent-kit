#!/usr/bin/env bash
# SessionStart: 설치된 킷이 로컬 킷 클론보다 낡았는지 한 줄로 알린다.
#
# 왜 CI 가 아니라 여기인가 — CI 에서 하려면 러너가 킷 레포를 읽어야 하고,
# 킷이 private 이면 repo secrets 에 토큰을 넣어야 한다. 낡음 감지는 정확성
# 게이트가 아니라 편의다(놓쳐도 깨지지 않고 옛 킷 코드를 쓸 뿐이다).
# 그 정도에 보안 표면을 늘리는 건 수지가 안 맞는다. 나중에 킷을 public 으로
# 바꾸거나 deploy key 를 넣으면 CI 계층을 얹으면 된다.
#
# 절대 차단하지 않는다. 알 수 없으면 조용히 넘어간다.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
[ -f .ai-kit/VERSION ] || exit 0

# 킷 경로는 install.sh 가 이 레포의 로컬 git config 에 적어둔다.
# 커밋되는 파일에 넣지 않는 이유: 머신마다 경로가 다르고, 남의 절대경로가
# 레포에 박히면 그 사람 환경을 알려주는 것 외에 아무 값도 없다.
kit=$(git config --get ai-kit.path 2>/dev/null) || exit 0
[ -n "$kit" ] && [ -d "$kit/.git" ] || exit 0

recorded=$(sed -n 's/^kit_rev=//p' .ai-kit/VERSION | head -1)
[ -n "$recorded" ] && [ "$recorded" != "unknown" ] || exit 0
latest=$(git -C "$kit" rev-parse --short HEAD 2>/dev/null) || exit 0
[ "$recorded" = "$latest" ] && exit 0

# 기록된 커밋이 킷에 실재하는지 확인한다. 없으면(재작성·다른 킷) 커밋 수를
# 세지 않는다 — 틀린 숫자를 말하느니 숫자를 빼는 편이 낫다.
if git -C "$kit" cat-file -e "${recorded}^{commit}" 2>/dev/null; then
  behind=$(git -C "$kit" rev-list --count "${recorded}..HEAD" 2>/dev/null || echo "")
  [ -n "$behind" ] && [ "$behind" != "0" ] \
    && echo "ai-kit: 설치된 킷이 ${behind}개 커밋 낡았습니다 (${recorded} → ${latest}). 확인: ${kit}/install.sh --update --dry-run"
else
  echo "ai-kit: 설치된 킷 리비전 ${recorded} 을 로컬 킷에서 찾을 수 없습니다 (현재 ${latest}). 확인: ${kit}/install.sh --update --dry-run"
fi
exit 0
