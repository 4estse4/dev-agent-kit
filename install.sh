#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh                     로컬 전부 (훅·템플릿·린트·CI·도구설정)
#   <kit>/install.sh --hooks --lint      선택 설치
#   <kit>/install.sh --protect           GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#   <kit>/install.sh --tools claude-code,codex
#
# 기존 파일은 절대 덮어쓰지 않는다. 충돌 시 .ai-kit-new 접미사로 옆에 두고 알린다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "install: git 레포 안에서 실행하세요" >&2; exit 1; }

DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 TOOLS=""
if [ $# -eq 0 ]; then
  DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1; TOOLS="claude-code"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    --protect) DO_PROTECT=1; shift ;;
    --tools) TOOLS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "install: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

INSTALLED=(); SKIPPED=(); CONFLICTS=(); WARNINGS=()

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
  cp -R "$KIT_ROOT/common/gate" "$KIT_ROOT/common/git-hooks" "$vendor/"
  # 활성화 절차가 레포 안에 있어야 한다 — install.sh 는 킷 레포에만 있으므로
  # 이 레포만 clone 한 사람은 훅을 켜는 방법을 알 길이 없다.
  cp "$KIT_ROOT/common/gate/VENDOR-README.md" "$vendor/README.md"
  rm -f "$vendor/gate/VENDOR-README.md"
  chmod +x "$vendor"/gate/*.sh "$vendor"/git-hooks/* 2>/dev/null
  # VERSION 에 킷 커밋과 vendor 내용 체크섬을 함께 적는다.
  # 커밋만 적으면 파일을 손으로 고쳤을 때 버전 표시가 거짓말을 한다 —
  # 체크섬이 있으면 CI 가 재계산해서 드리프트를 잡을 수 있다.
  kit_rev=$( cd "$KIT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown )
  # 체크섬 계산은 vendor 된 lib.sh 의 정의를 쓴다 — CI 도 같은 함수를 부른다.
  # shellcheck source=/dev/null
  . "$vendor/gate/lib.sh"
  sum=$(gate_checksum "$vendor") || sum="no-hasher"
  printf 'kit_rev=%s\nchecksum=%s\n' "$kit_rev" "$sum" > "$vendor/VERSION"
  INSTALLED+=(".ai-kit/ (게이트 vendor · $kit_rev · $sum)")

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 평가자가 레포를 받으면 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
  INSTALLED+=("core.hooksPath → .ai-kit/git-hooks (커밋되는 훅)")

  # 기존 .git/hooks 에 커스텀 훅이 있으면 알린다 — hooksPath 설정 시 무시된다.
  for h in pre-commit pre-push commit-msg; do
    f="$TARGET/.git/hooks/$h"
    [ -f "$f" ] && ! grep -q 'ai-kit' "$f" 2>/dev/null \
      && WARNINGS+=(".git/hooks/$h 가 있지만 core.hooksPath 설정으로 무시됩니다 — 필요하면 .ai-kit/git-hooks 로 옮기세요")
  done

  # ── 신원 고정 파일 시드 ──
  # 현재 실효 신원을 기대값으로 기록해두면, 이후 잘못된 신원 커밋을 훅이 막는다.
  eff_now=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$eff_now" ] && [ ! -f "$vendor/identity" ]; then
    printf '# 이 레포에서 커밋할 이메일. pre-commit 훅이 검증한다.\n%s\n' "$eff_now" > "$vendor/identity"
    INSTALLED+=(".ai-kit/identity ($eff_now)")
  fi

  # ── git 신원 확인 ──
  # 기존 커밋의 author 와 실효 설정이 다르면 기여 이력이 갈라진다.
  hist=$(git -C "$TARGET" log --format='%ae' 2>/dev/null | sort -u | head -3)
  eff=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$hist" ] && [ -n "$eff" ] && ! printf '%s\n' "$hist" | grep -qx "$eff"; then
    WARNINGS+=("git 신원 불일치 — 기존 커밋: $(printf '%s ' $hist)/ 현재 설정: $eff")
    WARNINGS+=("  → 이 레포에 고정: git config user.email '<쓸 이메일>'")
    WARNINGS+=("  → 또는 ~/.gitconfig 의 includeIf 에 이 레포 경로를 추가")
  fi
fi

# ── 템플릿: 파일마다 목적지가 다르므로 명시적으로 매핑한다 ──
# 추측(전부 docs/ 로)하면 AGENTS.md·PR 템플릿이 엉뚱한 데로 간다.
if [ "$DO_TEMPLATES" = 1 ]; then
  T="$KIT_ROOT/common/templates"
  place "$T/AGENTS.md"                 "AGENTS.md"
  place "$T/CLAUDE.md"                 "CLAUDE.md"
  place "$T/SPEC.md"                   "docs/SPEC.md"
  place "$T/traceability.md"           "docs/traceability.md"
  place "$T/dev-log.md"                "docs/dev-log.md"
  place "$T/RUNBOOK.md"                "docs/RUNBOOK.md"
  place "$T/adr.md"                    "docs/adr/0000-template.md"
  place "$T/plan.md"                   "docs/plan/0000-template.md"
  place "$T/PULL_REQUEST_TEMPLATE.md"  ".github/PULL_REQUEST_TEMPLATE.md"
  # 설계 근거 문서는 프로젝트와 함께 다녀야 한다 — AGENTS.md 가 이것을 인용하는데
  # 킷 레포 경로로 가리키면 레포만 clone 한 사람은 따라갈 수 없다.
  for d in "$KIT_ROOT"/common/docs/*.md; do
    [ -f "$d" ] || continue
    place "$d" "docs/process/$(basename "$d")"
  done
fi

if [ "$DO_LINT" = 1 ]; then
  [ -f "$TARGET/backend/go.mod" ] && place "$KIT_ROOT/common/lint/go/.golangci.yml" "backend/.golangci.yml"
  [ -f "$TARGET/go.mod" ]         && place "$KIT_ROOT/common/lint/go/.golangci.yml" ".golangci.yml"
  [ -f "$TARGET/frontend/package.json" ] && place "$KIT_ROOT/common/lint/ts/eslint.config.js" "frontend/eslint.config.js"
  [ -f "$TARGET/package.json" ]          && place "$KIT_ROOT/common/lint/ts/eslint.config.js" "eslint.config.js"
fi

if [ "$DO_CI" = 1 ]; then
  for f in "$KIT_ROOT"/common/ci/*.yml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    # dependabot.yml 은 워크플로가 아니라 .github/ 루트에 있어야 인식된다.
    case "$b" in
      dependabot.yml) place "$f" ".github/$b" ;;
      *)              place "$f" ".github/workflows/$b" ;;
    esac
  done
fi

# ── 도구별 설정: 목적지가 다르다. README 같은 킷 문서는 설치하지 않는다. ──
IFS=',' read -ra BL <<< "$TOOLS"
for b in "${BL[@]:-}"; do
  [ -z "$b" ] && continue
  bdir="$KIT_ROOT/$b"
  [ -d "$bdir" ] || { echo "install: 그런 도구가 없음 — $b" >&2; continue; }
  case "$b" in
    claude-code)
      while IFS= read -r f; do
        rel=${f#"$bdir"/}
        [ "$rel" = "README.md" ] && continue
        place "$f" ".claude/$rel"
      done < <(find "$bdir" -type f)
      ;;
    codex)
      # 설치할 설정 파일이 없다 — 검증 안 된 스텁을 두지 않기로 했다.
      # codex/README.md 의 "실제로 Codex 를 도입할 때 할 일" 참조.
      echo "install: codex 는 설치할 설정 파일이 없습니다 — codex/README.md 를 보세요" >&2
      ;;
    *) echo "install: 배치 규칙 없음 — $b" >&2 ;;
  esac
done

# ── 원격 변경: 브랜치 보호 ──
if [ "$DO_PROTECT" = 1 ]; then
  bash "$KIT_ROOT/common/ci/protect-branch.sh" || echo "install: 브랜치 보호 설정 실패" >&2
fi

# ── 보고 (산출물 규칙 R1: 개수만, 문제만 자세히) ──
echo "설치 ${#INSTALLED[@]}건 · 건너뜀 ${#SKIPPED[@]}건 · 충돌 ${#CONFLICTS[@]}건 · 확인필요 ${#WARNINGS[@]}건"
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
  echo ""; echo "충돌 — 기존 파일을 보존했고 새 것은 .ai-kit-new 로 옆에 뒀습니다. 확인 후 병합하세요:"
  printf '  %s\n' "${CONFLICTS[@]}"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""; echo "확인 필요:"
  printf '  %s\n' "${WARNINGS[@]}"
fi
