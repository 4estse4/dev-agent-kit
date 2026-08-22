#!/usr/bin/env bash
# 머신 단위 계층을 ~/.claude 에 설치한다. 프로젝트와 무관하게 한 번만.
# 기존 파일은 덮어쓰지 않는다 — 다르면 .ai-kit-new 로 옆에 두고 알린다.
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST="${CLAUDE_HOME:-$HOME/.claude}"
mkdir -p "$DEST"

INSTALLED=(); SAME=(); CONFLICT=(); STALE=(); MISSING=()

place() {
  local src="$SELF/$1" dst="$DEST/$1"
  # 소스가 없으면 조용히 넘기지 않는다. 킷에서 파일 이름이 바뀌거나 사라지면
  # 이 스크립트는 "설치 3건" 이라 말하고 하나를 빠뜨린 채 끝난다 — 그건 킷의
  # 결함이지 건너뛸 일이 아니다. (cp 자체의 실패는 방어하지 않는다 — R7.)
  [ -f "$src" ] || { MISSING+=("$1"); return; }
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
    # 이미 있으면 건드리지 않는다. 다만 "동일" 로 세지 않는다 —
    # 내용이 다른데 동일이라 보고하면 낡은 스킬을 쓰고 있다는 걸 영영 모른다.
    if [ -e "$DEST/skills/$name" ]; then
      if diff -rq "$d" "$DEST/skills/$name" >/dev/null 2>&1; then
        SAME+=("skills/$name")
      else
        STALE+=("skills/$name")
      fi
      continue
    fi
    mkdir -p "$DEST/skills" && cp -R "$d" "$DEST/skills/$name" && INSTALLED+=("skills/$name")
  done
fi
chmod +x "$DEST/statusline-command.sh" 2>/dev/null

echo "operator — 설치 ${#INSTALLED[@]} · 동일 ${#SAME[@]} · 충돌 ${#CONFLICT[@]} · 낡음 ${#STALE[@]}"
if [ ${#STALE[@]} -gt 0 ]; then
  echo ""
  echo "이미 있어 건드리지 않았지만 킷과 내용이 다릅니다 — 갱신하려면 지우고 다시 실행하세요:"
  for f in "${STALE[@]}"; do echo "  $DEST/$f  (킷: $SELF/$f)"; done
fi
if [ ${#CONFLICT[@]} -gt 0 ]; then
  echo ""
  echo "충돌 — 기존 파일을 보존했습니다. 확인 후 병합하세요:"
  for f in "${CONFLICT[@]}"; do echo "  $DEST/$f  ↔  $DEST/$f.ai-kit-new"; done
  echo ""
  echo "settings.json 은 병합 대상이다 — 통째로 덮으면 다른 설정이 사라진다."
fi

# 킷에 소스가 없는 것은 이 스크립트의 버그다 — 조용히 덜 설치하고 끝내지 않는다.
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "" >&2
  echo "킷에 소스가 없어 설치하지 못했습니다 — install-operator.sh 와 operator/ 가 어긋났습니다:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi
