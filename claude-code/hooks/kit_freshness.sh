#!/usr/bin/env bash
# SessionStart: 설치된 킷이 로컬 킷 클론보다 낡았는지 한 줄로 알린다.
#
# 왜 CI 가 아니라 여기인가 — CI 에서 하려면 러너가 킷 레포를 읽어야 한다.
#
# **킷과 프로젝트가 같은 사람의 private 레포여도 안 된다.** Actions 가 자동으로 주는
# GITHUB_TOKEN 은 그 워크플로가 도는 레포에만 권한이 있다. 다른 레포를 읽으려면
# PAT 이나 deploy key 를 그 프로젝트의 secrets 에 넣어야 하고, 그러면 **킷을 읽을 수
# 있는 자격증명이 프로젝트 레포마다 복제된다.**
#
# 낡음 감지는 정확성 게이트가 아니라 편의다 — 놓쳐도 깨지지 않고 옛 킷 코드를 쓸 뿐이다.
# 그 정도에 자격증명을 퍼뜨리는 건 수지가 안 맞는다. 킷을 public 으로 바꾸면
# 토큰 없이 읽히므로 그때 CI 계층을 얹으면 된다.
#
# 절대 차단하지 않는다. 알 수 없으면 조용히 넘어간다.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
STAMP=.ai-kit/install-manifest
[ -f "$STAMP" ] || exit 0

# 킷 경로는 install.sh 가 이 레포의 로컬 git config 에 적어둔다.
# 커밋되는 파일에 넣지 않는 이유: 머신마다 경로가 다르고, 남의 절대경로가
# 레포에 박히면 그 사람 환경을 알려주는 것 외에 아무 값도 없다.
kit=$(git config --get ai-kit.path 2>/dev/null) || exit 0
[ -n "$kit" ] || exit 0
# 경로가 적혀 있는데 그것이 사라진 경우와, 애초에 킷 설정이 없는 경우는 다르다.
# 전자를 조용히 넘기면 낡음 감지가 꺼진 것을 아무도 모른다 — 사용자 눈에는
# "킷이 최신이다" 와 구분되지 않는다.
if [ ! -d "$kit/.git" ]; then
  echo "킷 클론을 찾을 수 없습니다 ($kit) — 낡음 감지가 꺼져 있습니다."
  echo "  다시 clone 하거나 install.sh 를 다시 돌리면 경로가 갱신됩니다."
  exit 0
fi

recorded=$(sed -n 's/^kit_rev=//p' "$STAMP" | head -1)
[ -n "$recorded" ] && [ "$recorded" != "unknown" ] || exit 0
latest=$(git -C "$kit" rev-parse --short HEAD 2>/dev/null) || exit 0
[ "$recorded" = "$latest" ] && exit 0

# 기록된 커밋이 킷에 실재하는지 확인한다. 없으면(재작성·다른 킷) 커밋 수를
# 세지 않는다 — 틀린 숫자를 말하느니 숫자를 빼는 편이 낫다.
if git -C "$kit" cat-file -e "${recorded}^{commit}" 2>/dev/null; then
  behind=$(git -C "$kit" rev-list --count "${recorded}..HEAD" 2>/dev/null || echo "")
  [ -n "$behind" ] && [ "$behind" != "0" ] \
    && echo "ai-kit: 설치된 킷이 ${behind}개 커밋 낡았습니다 (${recorded} → ${latest}). 확인: ${kit}/install.sh . --dry-run"
else
  echo "ai-kit: 설치된 킷 리비전 ${recorded} 을 로컬 킷에서 찾을 수 없습니다 (현재 ${latest}). 확인: ${kit}/install.sh . --dry-run"
fi
exit 0
