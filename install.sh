#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh <프로젝트경로>      로컬 전부 (훅·템플릿·린트·CI·도구설정)
#                                        경로는 필수. 현재 위치면 "." 를 준다.
#   <kit>/install.sh <경로> --hooks --lint   선택 설치
#   <kit>/install.sh --protect           GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#   <kit>/install.sh --tools claude-code,codex
#   <kit>/install.sh <경로> --update         설치된 킷을 갱신 (3-way 병합)
#   <kit>/install.sh <경로> --update --dry-run   무엇이 바뀔지만 보고 아무것도 안 건드림
#
# 설치: 기존 파일은 절대 덮어쓰지 않는다. 충돌 시 .ai-kit-new 로 옆에 두고 알린다.
# 갱신: 설치 시점의 킷 원본을 .ai-kit/baseline/ 에 남겨두고, 그것을 base 로 3-way
#       병합한다. 프로젝트 수정과 킷 변경이 겹치지 않으면 조용히 둘 다 살아남는다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 TOOLS="" DO_UPDATE=0 DRY_RUN=0 TARGET_ARG=""
# 플래그가 하나도 없으면(경로만 있거나 아무것도 없으면) 전부 설치한다.
case " $* " in
  *" --"*) ;;
  *) DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1; TOOLS="claude-code" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    --protect) DO_PROTECT=1; shift ;;
    --tools) TOOLS="${2:-}"; shift 2 ;;
    --update) DO_UPDATE=1; DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1; TOOLS="claude-code"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "install: 알 수 없는 인자 $1" >&2; exit 2 ;;
    *)
      [ -n "$TARGET_ARG" ] && { echo "install: 프로젝트 경로는 하나만 받습니다" >&2; exit 2; }
      TARGET_ARG="$1"; shift ;;
  esac
done

# 대상 경로는 **필수**다. CWD 로 폴백하지 않는다.
#
# 이 명령은 레포에 파일 30개 가까이를 쓰고 git config 를 바꾼다. 되돌리기 번거로운
# 쓰기 작업에서 "아마 여기겠지" 를 추측하면 안 된다 — 실제로 두 번 물렸다(킷 레포에
# 자기 자신을 설치, 엉뚱한 레포에 git add). 대상을 출력하는 것으로는 부족하다.
# 출력하고 곧바로 설치하므로 사람이 읽었을 때는 이미 끝나 있다.
#
# 지금 있는 레포에 설치하려면 점 하나면 된다: install.sh .
if [ -z "$TARGET_ARG" ]; then
  echo "install: 프로젝트 경로가 필요합니다" >&2
  echo "  <kit>/install.sh <프로젝트경로>     예: <kit>/install.sh ~/work/myproj" >&2
  echo "  <kit>/install.sh .                   지금 있는 레포에 설치" >&2
  exit 2
fi
[ -d "$TARGET_ARG" ] || { echo "install: 그런 디렉터리가 없습니다 — $TARGET_ARG" >&2; exit 1; }
TARGET=$(git -C "$TARGET_ARG" rev-parse --show-toplevel 2>/dev/null) \
  || { echo "install: git 레포가 아닙니다 — $TARGET_ARG" >&2; exit 1; }
echo "install: 대상 $TARGET"
echo "install: 킷   $KIT_ROOT"

INSTALLED=(); SKIPPED=(); CONFLICTS=(); WARNINGS=(); MERGED=(); UNCHANGED=(); SEEDED=()
# 설치 시점 킷 리비전. baseline 이 없을 때 이것으로 원본을 복원한다.
KIT_REV=""
if [ -f "$TARGET/.ai-kit/VERSION" ]; then
  KIT_REV=$(sed -n 's/^kit_rev=//p' "$TARGET/.ai-kit/VERSION" | head -1)
  [ "$KIT_REV" = "unknown" ] && KIT_REV=""
  if [ -n "$KIT_REV" ] && ! git -C "$KIT_ROOT" cat-file -e "${KIT_REV}^{commit}" 2>/dev/null; then
    WARNINGS+=("기록된 킷 리비전 $KIT_REV 을 이 킷 클론에서 찾을 수 없습니다 — baseline 복원 불가")
    WARNINGS+=("  킷 히스토리를 재작성했다면 그때 끊긴 것입니다. 해당 파일은 손으로 확인해야 합니다.")
    KIT_REV=""
  fi
fi

BASELINE="$TARGET/.ai-kit/baseline"
# 충돌 마커에 절대경로가 박히면 읽기 어렵다. 사람이 읽는 자리이므로 이름을 준다.
MF_L='-L 이_레포 -L 설치시점_킷 -L 새_킷'

# 설치 시점의 킷 원본을 남긴다. 이것이 없으면 나중에 "프로젝트가 고친 것"과
# "킷이 바꾼 것"을 구분할 수 없어, 갱신이 덮어쓰기 아니면 포기 둘 중 하나가 된다.
save_baseline() { # $1=src $2=dst(상대)
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$BASELINE/$(dirname "$2")" && cp "$1" "$BASELINE/$2"
}

# 기존 파일을 보존하며 복사한다(설치).
place() { # $1=src $2=dst(대상 레포 상대)
  local src="$1" dst="$TARGET/$2"
  [ "$DO_UPDATE" = 1 ] && { merge_place "$1" "$2"; return; }
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then SKIPPED+=("$2 (동일)"); save_baseline "$src" "$2"; return; fi
    cp "$src" "$dst.ai-kit-new"; CONFLICTS+=("$2"); return
  fi
  cp "$src" "$dst"; save_baseline "$src" "$2"; INSTALLED+=("$2")
}

# baseline 이 없는 레포(=baseline 기능 이전에 설치)에서, 기록된 kit_rev 로 그 시점
# 킷 원본을 복원한다. 정보는 이미 .ai-kit/VERSION 에 있었고 쓰지 않았을 뿐이다.
#
# 경로는 하드코딩하지 않는다 — 킷 안에서 파일이 옮겨다니므로(core/ → common/ 등)
# git 의 이름 추적에 맡긴다. 그 시점에 없던 파일은 "없음" 이 올바른 답이다.
seed_baseline() { # $1=킷의 현재 경로 $2=써넣을 파일 → 성공 시 0
  [ -n "$KIT_REV" ] || return 1
  local old
  old=$(git -C "$KIT_ROOT" log --follow --format='' --name-only "$KIT_REV..HEAD" -- "$1" 2>/dev/null \
        | grep -v '^$' | tail -1)
  [ -n "$old" ] || old="$1"
  git -C "$KIT_ROOT" cat-file -e "$KIT_REV:$old" 2>/dev/null || return 1
  mkdir -p "$(dirname "$2")" || return 1
  git -C "$KIT_ROOT" show "$KIT_REV:$old" > "$2" 2>/dev/null
}

# 갱신: base=설치 시점 킷 원본, ours=프로젝트 현재, theirs=킷 새 버전.
merge_place() { local _r; _merge_place "$@"; _r=$?; [ -n "${MP_TMP:-}" ] && rm -f "$MP_TMP"; MP_TMP=""; return $_r; }
_merge_place() { # $1=src(킷 새 버전) $2=dst(상대)
  local src="$1" rel="$2" dst="$TARGET/$2" base="$BASELINE/$2" rc

  # baseline 이 없으면 기록된 kit_rev 로 복원해본다(baseline 기능 이전에 설치된 레포).
  # dry-run 이면 임시 파일에 복원한다 — 판정은 똑같이 하되 레포는 안 건드린다.
  local tmpbase=""
  MP_TMP=""
  if [ ! -f "$base" ] && [ -n "$KIT_REV" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      tmpbase=$(mktemp)
      if seed_baseline "$src" "$tmpbase"; then base="$tmpbase"; MP_TMP="$tmpbase"; SEEDED+=("$rel"); else rm -f "$tmpbase"; fi
    else
      seed_baseline "$src" "$base" && SEEDED+=("$rel")
    fi
  fi

  # 복원도 안 되면 이 파일은 킷이 설치한 적이 없다 — 갱신이 아니라 신규 설치다.
  if [ ! -f "$base" ]; then
    if [ -e "$dst" ]; then
      cmp -s "$src" "$dst" && { SKIPPED+=("$rel (동일)"); save_baseline "$src" "$rel"; return; }
      CONFLICTS+=("$rel (baseline 없음 — 손으로 확인)")
      [ "$DRY_RUN" = 1 ] || cp "$src" "$dst.ai-kit-new"
      return
    fi
    [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
    save_baseline "$src" "$rel"; INSTALLED+=("$rel"); return
  fi

  # 킷 쪽이 그대로면 할 일이 없다. 프로젝트가 고쳤든 아니든 건드리지 않는다.
  cmp -s "$base" "$src" && { UNCHANGED+=("$rel"); return; }

  # 프로젝트가 손대지 않았으면 병합할 것이 없다 — 그냥 새 버전으로 간다.
  if [ ! -e "$dst" ] || cmp -s "$base" "$dst"; then
    [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
    save_baseline "$src" "$rel"; INSTALLED+=("$rel (킷 변경 반영)"); return
  fi

  # 양쪽이 다 움직였다 — 3-way 병합. 종료코드가 곧 충돌 수다.
  if [ "$DRY_RUN" = 1 ]; then
    local tmp; tmp=$(mktemp); cp "$dst" "$tmp"
    git merge-file -q $MF_L "$tmp" "$base" "$src" >/dev/null 2>&1; rc=$?
    rm -f "$tmp"
    [ "$rc" -eq 0 ] && MERGED+=("$rel") || CONFLICTS+=("$rel ($rc 곳 충돌)")
    return
  fi
  # shellcheck disable=SC2086
  git merge-file $MF_L "$dst" "$base" "$src" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    MERGED+=("$rel"); save_baseline "$src" "$rel"
  else
    # 충돌 마커를 파일에 남긴다. 에디터와 git 이 그대로 다루는 형식이라
    # 별도 도구를 배울 필요가 없다. baseline 은 갱신하지 않는다 —
    # 사람이 해소한 뒤 다시 돌려야 다음 갱신의 base 가 맞다.
    CONFLICTS+=("$rel ($rc 곳 충돌 — 마커를 남겼습니다)")
  fi
}

# ── 게이트 vendor: 대상 레포에 .ai-kit/ 로 복사한다 ──
# 홈 디렉터리 경로를 훅·CI 에 박으면 다른 머신과 CI 에서 깨진다.
# vendor 해서 레포에 커밋하면 어디서 clone 해도 같은 게이트가 돈다.
if [ "$DO_HOOKS" = 1 ]; then
  vendor="$TARGET/.ai-kit"
  # .ai-kit/gate 와 git-hooks 는 킷 소유라 통째로 교체한다(프로젝트가 고치면 CI 가 잡는다).
  # baseline/ 과 identity 는 그 아래 살지만 킷 소유가 아니므로 남긴다 —
  # baseline 을 지우면 다음 갱신이 3-way 병합의 base 를 잃는다.
  if [ "$DRY_RUN" = 1 ]; then
    UNCHANGED+=(".ai-kit/gate · git-hooks (갱신 모드에서는 통째로 교체)")
  else
  rm -rf "$vendor/gate" "$vendor/git-hooks" "$vendor/README.md"
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

  fi

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 평가자가 레포를 받으면 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
  INSTALLED+=("core.hooksPath → .ai-kit/git-hooks (커밋되는 훅)")

  # 킷 클론의 경로를 이 레포의 로컬 git config 에 적는다 — 커밋되지 않는다.
  # SessionStart 훅이 이것으로 "설치된 킷이 낡았나" 를 판정한다. 커밋되는 파일에
  # 넣지 않는 이유: 머신마다 경로가 다르고, 남의 절대경로가 레포에 박히면
  # 그 사람 환경을 알려주는 것 말고는 아무 값도 없다.
  git -C "$TARGET" config ai-kit.path "$KIT_ROOT" 2>/dev/null

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
if [ "$DO_UPDATE" = 1 ]; then
  [ "$DRY_RUN" = 1 ] && echo "── dry-run: 아무것도 바꾸지 않았습니다 ──"
  echo "갱신 ${#INSTALLED[@]}건 · 병합 ${#MERGED[@]}건 · 그대로 ${#UNCHANGED[@]}건 · 동일 ${#SKIPPED[@]}건 · 충돌 ${#CONFLICTS[@]}건"
  [ ${#SEEDED[@]} -gt 0 ] && echo "(baseline 이 없어 kit_rev $KIT_REV 로 ${#SEEDED[@]}건 복원했습니다)"
  if [ ${#INSTALLED[@]} -gt 0 ]; then echo ""; echo "킷 변경이 반영됨:"; printf '  %s\n' "${INSTALLED[@]}"; fi
  if [ ${#MERGED[@]} -gt 0 ]; then echo ""; echo "프로젝트 수정과 함께 병합됨:"; printf '  %s\n' "${MERGED[@]}"; fi
else
echo "설치 ${#INSTALLED[@]}건 · 건너뜀 ${#SKIPPED[@]}건 · 충돌 ${#CONFLICTS[@]}건 · 확인필요 ${#WARNINGS[@]}건"
fi
if [ "$DO_HOOKS" = 1 ] && [ "$DO_UPDATE" = 0 ]; then
  cat <<'MSG'

.ai-kit/ 를 커밋하세요 — 게이트와 훅이 레포와 함께 버전 관리됩니다.

  주의: core.hooksPath 는 로컬 설정이라 clone 을 따라가지 않습니다(git 의 보안 설계).
  새로 clone 한 사람은 한 줄로 활성화합니다:

      git config core.hooksPath .ai-kit/git-hooks

  그래서 로컬 훅은 '조기 피드백'이고, 우회 불가능한 강제는 CI + 브랜치 보호입니다.
MSG
fi
if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo ""
  if [ "$DO_UPDATE" = 1 ]; then
    echo "충돌 — 아래는 손으로 해소한 뒤 --update 를 다시 돌리세요(그래야 baseline 이 맞습니다):"
  else
    echo "충돌 — 기존 파일을 보존했고 새 것은 .ai-kit-new 로 옆에 뒀습니다. 확인 후 병합하세요:"
  fi
  printf '  %s\n' "${CONFLICTS[@]}"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""; echo "확인 필요:"
  printf '  %s\n' "${WARNINGS[@]}"
fi
