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

# ── 게이트 vendor: 대상 레포에 .ai-kit/ 로 복사한다 ──
# 홈 디렉터리 경로를 훅·CI 에 박으면 다른 머신과 CI 에서 깨진다.
# vendor 해서 레포에 커밋하면 어디서 clone 해도 같은 게이트가 돈다.
if [ "$DO_HOOKS" = 1 ]; then
  vendor="$TARGET/.ai-kit"
  rm -rf "$vendor"
  mkdir -p "$vendor"
  cp -R "$KIT_ROOT/core/gate" "$KIT_ROOT/core/git-hooks" "$vendor/"
  ( cd "$KIT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown ) > "$vendor/VERSION"
  chmod +x "$vendor"/gate/*.sh "$vendor"/git-hooks/* 2>/dev/null
  INSTALLED+=(".ai-kit/ (게이트 vendor · $(cat "$vendor/VERSION"))")

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 평가자가 레포를 받으면 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
  INSTALLED+=("core.hooksPath → .ai-kit/git-hooks (커밋되는 훅)")

  # 기존 .git/hooks 에 커스텀 훅이 있으면 알린다 — hooksPath 설정 시 무시된다.
  for h in pre-commit pre-push commit-msg; do
    f="$TARGET/.git/hooks/$h"
    [ -f "$f" ] && ! grep -q 'ai-kit' "$f" 2>/dev/null \
      && CONFLICTS+=(".git/hooks/$h (core.hooksPath 설정으로 이제 무시됨 — 필요하면 .ai-kit/git-hooks 로 옮기세요)")
  done

  # ── git 신원 확인 ──
  # 기존 커밋의 author 와 실효 설정이 다르면 기여 이력이 갈라진다.
  hist=$(git -C "$TARGET" log --format='%ae' 2>/dev/null | sort -u | head -3)
  eff=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$hist" ] && [ -n "$eff" ] && ! printf '%s\n' "$hist" | grep -qx "$eff"; then
    CONFLICTS+=("git 신원 불일치 — 기존 커밋: $(printf '%s ' $hist)/ 현재 설정: $eff")
    CONFLICTS+=("  → git -C $TARGET config user.email '<쓸 이메일>' 로 레포에 고정하세요")
  fi
fi

[ "$DO_TEMPLATES" = 1 ] && for f in "$KIT_ROOT"/core/templates/*; do
  [ -f "$f" ] || continue; place "$f" "docs/$(basename "$f")"
done

if [ "$DO_LINT" = 1 ]; then
  [ -f "$TARGET/backend/go.mod" ] && place "$KIT_ROOT/core/lint/go/.golangci.yml" "backend/.golangci.yml"
  [ -f "$TARGET/go.mod" ]         && place "$KIT_ROOT/core/lint/go/.golangci.yml" ".golangci.yml"
fi

if [ "$DO_CI" = 1 ]; then
  for f in "$KIT_ROOT"/core/ci/*.yml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    # dependabot.yml 은 워크플로가 아니라 .github/ 루트에 있어야 인식된다.
    case "$b" in
      dependabot.yml) place "$f" ".github/$b" ;;
      *)              place "$f" ".github/workflows/$b" ;;
    esac
  done
fi

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
if [ "$DO_HOOKS" = 1 ]; then
  cat <<'MSG'

.ai-kit/ 를 커밋하세요 — 게이트와 훅이 레포와 함께 버전 관리됩니다.

  주의: core.hooksPath 는 로컬 설정이라 clone 을 따라가지 않습니다(git 의 보안 설계).
  새로 clone 한 사람은 한 줄로 활성화합니다:

      git config core.hooksPath .ai-kit/git-hooks

  그래서 로컬 훅은 '조기 피드백'이고, 우회 불가능한 강제는 CI + 브랜치 보호입니다.
MSG
fi
if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo ""; echo "충돌 — 기존 파일을 보존했습니다. 확인 후 병합하세요:"
  printf '  %s\n' "${CONFLICTS[@]}"
fi
