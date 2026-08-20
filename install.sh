#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh                     로컬 전부 (훅·템플릿·린트·CI·바인딩)
#   <kit>/install.sh --hooks --lint      선택 설치
#   <kit>/install.sh --protect           GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#   <kit>/install.sh --bindings claude-code,codex
#
# 기존 파일은 절대 덮어쓰지 않는다. 충돌 시 .ai-kit-new 접미사로 옆에 두고 알린다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "install: git 레포 안에서 실행하세요" >&2; exit 1; }

DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 BINDINGS=""
if [ $# -eq 0 ]; then
  DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1; BINDINGS="claude-code"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    --protect) DO_PROTECT=1; shift ;;
    --bindings) BINDINGS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "install: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

INSTALLED=(); SKIPPED=(); CONFLICTS=()

# 기존 파일을 보존하며 복사한다.
place() { # $1=src $2=dst(대상 레포 상대)
  local src="$1" dst="$TARGET/$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then SKIPPED+=("$2 (동일)"); return; fi
    cp "$src" "$dst.ai-kit-new"; CONFLICTS+=("$2"); return
  fi
  cp "$src" "$dst"; INSTALLED+=("$2")
}

# ── git 훅: 킷을 가리키는 shim 을 심는다(킷 갱신이 자동 반영) ──
if [ "$DO_HOOKS" = 1 ]; then
  hookdir="$TARGET/.git/hooks"; mkdir -p "$hookdir"
  for h in pre-commit pre-push; do
    if [ -e "$hookdir/$h" ] && ! grep -q "AI_KIT_ROOT" "$hookdir/$h" 2>/dev/null; then
      mv "$hookdir/$h" "$hookdir/$h.pre-ai-kit"
      CONFLICTS+=(".git/hooks/$h (기존 훅을 $h.pre-ai-kit 로 보존)")
    fi
    cat > "$hookdir/$h" <<EOF
#!/usr/bin/env bash
export AI_KIT_ROOT="$KIT_ROOT"
exec "\$AI_KIT_ROOT/core/git-hooks/$h" "\$@"
EOF
    chmod +x "$hookdir/$h"
    INSTALLED+=(".git/hooks/$h")
  done
fi

[ "$DO_TEMPLATES" = 1 ] && for f in "$KIT_ROOT"/core/templates/*; do
  [ -f "$f" ] || continue; place "$f" "docs/$(basename "$f")"
done

if [ "$DO_LINT" = 1 ]; then
  [ -f "$TARGET/backend/go.mod" ] && place "$KIT_ROOT/core/lint/go/.golangci.yml" "backend/.golangci.yml"
  [ -f "$TARGET/go.mod" ]         && place "$KIT_ROOT/core/lint/go/.golangci.yml" ".golangci.yml"
fi

[ "$DO_CI" = 1 ] && for f in "$KIT_ROOT"/core/ci/*.yml; do
  [ -f "$f" ] || continue; place "$f" ".github/workflows/$(basename "$f")"
done

IFS=',' read -ra BL <<< "$BINDINGS"
for b in "${BL[@]:-}"; do
  [ -z "$b" ] && continue
  bdir="$KIT_ROOT/bindings/$b"
  [ -d "$bdir" ] || { echo "install: 바인딩 없음 — $b" >&2; continue; }
  while IFS= read -r f; do
    rel=${f#"$bdir"/}
    case "$b" in
      claude-code) place "$f" ".claude/$rel" ;;
      codex)       place "$f" "$rel" ;;
    esac
  done < <(find "$bdir" -type f)
done

# ── 원격 변경: 브랜치 보호 ──
if [ "$DO_PROTECT" = 1 ]; then
  bash "$KIT_ROOT/core/ci/protect-branch.sh" || echo "install: 브랜치 보호 설정 실패" >&2
fi

# ── 보고 (산출물 규칙 R1: 개수만, 문제만 자세히) ──
echo "설치 ${#INSTALLED[@]}건 · 건너뜀 ${#SKIPPED[@]}건 · 충돌 ${#CONFLICTS[@]}건"
if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo ""; echo "충돌 — 기존 파일을 보존했습니다. 확인 후 병합하세요:"
  printf '  %s\n' "${CONFLICTS[@]}"
fi
