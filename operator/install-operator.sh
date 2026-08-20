#!/usr/bin/env bash
# 머신 단위 계층을 ~/.claude 에 설치한다. 프로젝트와 무관하게 한 번만.
# 기존 파일은 덮어쓰지 않는다 — 다르면 .ai-kit-new 로 옆에 두고 알린다.
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST="${CLAUDE_HOME:-$HOME/.claude}"
mkdir -p "$DEST"

INSTALLED=(); SAME=(); CONFLICT=()
place() {
  local src="$SELF/$1" dst="$DEST/$1"
  [ -f "$src" ] || return 0
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then SAME+=("$1"); return; fi
    cp "$src" "$dst.ai-kit-new"; CONFLICT+=("$1"); return
  fi
  cp "$src" "$dst"; INSTALLED+=("$1")
}

place statusline-command.sh
place CLAUDE.md
place settings.json

# 사용자 스킬 (디렉터리 단위)
if [ -d "$SELF/skills" ]; then
  for d in "$SELF"/skills/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if [ -e "$DEST/skills/$name" ]; then SAME+=("skills/$name (이미 있음 — 건드리지 않음)"); continue; fi
    mkdir -p "$DEST/skills" && cp -R "$d" "$DEST/skills/$name" && INSTALLED+=("skills/$name")
  done
fi
chmod +x "$DEST/statusline-command.sh" 2>/dev/null

echo "operator — 설치 ${#INSTALLED[@]} · 동일 ${#SAME[@]} · 충돌 ${#CONFLICT[@]}"
if [ ${#CONFLICT[@]} -gt 0 ]; then
  echo ""
  echo "충돌 — 기존 파일을 보존했습니다. 확인 후 병합하세요:"
  for f in "${CONFLICT[@]}"; do echo "  $DEST/$f  ↔  $DEST/$f.ai-kit-new"; done
  echo ""
  echo "settings.json 은 병합 대상이다 — 통째로 덮으면 다른 설정이 사라진다."
fi
