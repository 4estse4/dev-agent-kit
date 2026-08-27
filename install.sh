#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh <프로젝트경로>      로컬 전부 (훅·템플릿·린트·CI·도구설정)
#                                        경로는 필수. 현재 위치면 "." 를 준다.
#   <kit>/install.sh <경로> [--lang py,ts] --hooks --lint   선택 설치
#   <kit>/install.sh <경로> --protect           GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#   <kit>/install.sh <경로> [--lang py,ts] --update         설치된 킷을 갱신
#   <kit>/install.sh <경로> [--lang py,ts] --update --dry-run   무엇이 바뀔지만 보고 아무것도 안 건드림
#
# 설치: 기존 파일은 절대 덮어쓰지 않는다. 충돌 시 .ai-kit-new 로 옆에 두고 알린다.
# 갱신: 킷 소유 파일(.ai-kit/gate·git-hooks)은 통째로 교체한다. 그 밖의 파일은
#       **킷이 그것을 바꿨을 때만** .ai-kit-new 로 옆에 놓고 알린다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PROTECT_FAILED=0
DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 DO_AGENT=0 DO_UPDATE=0 DRY_RUN=0 TARGET_ARG="" LANGS=""
# 설치할 항목을 고르지 않았으면 전부 설치한다.
# --lang·--dry-run 은 항목이 아니라 수식이므로 여기서 세지 않는다 —
# 세면 `install.sh <경로> --lang py` 가 아무것도 설치하지 않고 끝난다.
case " $* " in
  *" --hooks"*|*" --templates"*|*" --lint"*|*" --ci"*|*" --protect"*|*" --update"*) ;;
  *) DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1 DO_AGENT=1 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    --lang) LANGS="${2:-}"; shift 2 ;;
    --lang=*) LANGS="${1#--lang=}"; shift ;;
    --protect) DO_PROTECT=1; shift ;;
    --update) DO_UPDATE=1; DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1 DO_AGENT=1; shift ;;
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

INSTALLED=(); NOOP=(); CONFLICTS=(); WARNINGS=()
ALL_LANGS="go ts jvm py"
# 갱신 시 --lang 을 안 주면 설치 당시 선택을 이어받는다 — 안 그러면 갱신이
# 조용히 언어를 도로 넣고 체크섬만 바뀐다.
STAMP="$TARGET/.ai-kit/install-manifest"
SUM_BEFORE=$(sed -n 's/^checksum=//p' "$STAMP" 2>/dev/null | head -1)
KIT_REV=""
KC_TMP=$(mktemp); trap 'rm -f "$KC_TMP"' EXIT
if [ -f "$STAMP" ]; then
  KIT_REV=$(sed -n 's/^kit_rev=//p' "$STAMP" | head -1)
  if [ -n "$KIT_REV" ] && ! git -C "$KIT_ROOT" cat-file -e "${KIT_REV}^{commit}" 2>/dev/null; then
    # dry-run 에서도 받는다. 이것은 **킷 클론**을 최신으로 만드는 읽기이지 대상
    # 레포의 상태가 아니다. 건너뛰면 예측이 실제 실행과 달라진다(재현함).
    git -C "$KIT_ROOT" fetch -q --all 2>/dev/null || true
  fi
  git -C "$KIT_ROOT" cat-file -e "${KIT_REV}^{commit}" 2>/dev/null || KIT_REV=""
fi
if [ -z "$LANGS" ] && [ -f "$STAMP" ]; then
  LANGS=$(sed -n 's/^langs=//p' "$STAMP" | head -1)
fi
[ -z "$LANGS" ] && LANGS=$(echo "$ALL_LANGS" | tr ' ' ',')
LANGS=$(echo "$LANGS" | tr -d ' ')
for _l in $(echo "$LANGS" | tr ',' ' '); do
  case " $ALL_LANGS " in *" $_l "*) ;;
    *) echo "install: 그런 언어가 없음 — $_l (가능: ${ALL_LANGS// /, })" >&2; exit 2 ;;
  esac
done
# 설치 때 고른 언어와 지금 요청이 다르면 gates.yml 은 다시 걸러야 한다.
# kit_changed() 는 킷 원본의 변경만 보므로 이 경우를 못 잡는다(필터 결과가 달라진다).
LANG_WAS=""
[ -f "$STAMP" ] && LANG_WAS=$(sed -n 's/^langs=//p' "$STAMP" | head -1)
LANG_CHANGED=0
[ -n "$LANG_WAS" ] && [ "$LANG_WAS" != "$LANGS" ] && LANG_CHANGED=1

DROP=""
for _l in $ALL_LANGS; do
  case ",$LANGS," in *",$_l,"*) ;; *) DROP="${DROP:+$DROP,}$_l" ;; esac
done


# 갱신 시 이미 있는 파일을 덮지 않는다. 킷의 새 버전을 <파일>.ai-kit-new 로 옆에
# 놓고 충돌로 보고한다 — 사람이 둘을 비교해 합친다.
#
# 자동 3-way 병합을 하지 않는다. base(설치 시점 킷 원본)를 어딘가 들고 있어야 하는데,
# 그러려면 baseline/ 27개 파일을 커밋시키거나 킷 히스토리에서 복원해야 했고,
# 두 경로 다 조용히 틀렸다. 편의 하나를 위해 부서지기 쉬운 층을 두지 않는다.
# 이 파일을 킷이 kit_rev 이후 바꿨나. 판정 못 하면 1(=바꿨다고 본다).
# 이것이 없으면 프로젝트가 채운 파일이 전부 충돌로 뜬다 — "프로젝트가 채웠다" 와
# "킷이 바꿨다" 가 구분되지 않기 때문이다. base 파일을 들고 있을 필요는 없고,
# **킷 안에서** 그 시점과 지금을 비교하면 된다.
# $KC_TMP 에는 호출 후 kit_rev 시점의 킷 원본이 담긴다(성공 시).
kit_changed() { # $1=킷 상대경로
  KC_OK=0
  [ -n "$KIT_REV" ] || return 0
  git -C "$KIT_ROOT" show "$KIT_REV:$1" 2>/dev/null > "$KC_TMP" || return 0
  KC_OK=1
  cmp -s "$KC_TMP" "$KIT_ROOT/$1" && return 1
  return 0
}

place() { # $1=src $2=dst(대상 레포 상대) [$3=킷 상대경로 — 빈 값이면 항상 "바뀜"]
  local src="$1" dst="$TARGET/$2" krel
  if [ $# -ge 3 ]; then krel="$3"; else krel="${1#"$KIT_ROOT"/}"; fi
  if [ -e "$dst" ]; then
    cmp -s "$src" "$dst" && { NOOP+=("$2"); return; }
    if [ "$DO_UPDATE" = 1 ]; then
      # 킷이 안 바꿨으면 프로젝트가 채운 것이다. 건드리지 않는다.
      if [ -n "$krel" ] && ! kit_changed "$krel"; then NOOP+=("$2"); return; fi
      [ -n "$krel" ] || KC_OK=0
      # 킷은 바꿨는데 프로젝트는 설치 때 그대로면 합칠 것이 없다 — 그냥 새 버전으로.
      # (KC_TMP 에 설치 시점 원본이 있으므로 "프로젝트가 손댔나" 를 여기서 알 수 있다.)
      if [ "$KC_OK" = 1 ] && cmp -s "$KC_TMP" "$dst"; then
        [ "$DRY_RUN" = 1 ] || cp "$src" "$dst"
        INSTALLED+=("$2 (킷 변경 반영)"); return
      fi
    fi
    [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst.ai-kit-new"; }
    CONFLICTS+=("$2"); return
  fi
  [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
  INSTALLED+=("$2")
}

# ── 게이트 vendor: 대상 레포에 .ai-kit/ 로 복사한다 ──
# 홈 디렉터리 경로를 훅·CI 에 박으면 다른 머신과 CI 에서 깨진다.
# vendor 해서 레포에 커밋하면 어디서 clone 해도 같은 게이트가 돈다.
if [ "$DO_HOOKS" = 1 ]; then
  vendor="$TARGET/.ai-kit"
  # .ai-kit/gate 와 git-hooks 는 킷 소유라 통째로 교체한다(프로젝트가 고치면 CI 가 잡는다).
  # identity 는 그 아래 살지만 킷 소유가 아니므로 남긴다.
  if [ "$DRY_RUN" = 1 ]; then
    INSTALLED+=(".ai-kit/gate · git-hooks (통째로 교체)")
  else
  rm -rf "$vendor/gate" "$vendor/git-hooks" "$vendor/README.md"
  mkdir -p "$vendor"
  cp -R "$KIT_ROOT/common/gate" "$KIT_ROOT/common/git-hooks" "$vendor/"
  # 활성화 절차가 레포 안에 있어야 한다 — install.sh 는 킷 레포에만 있으므로
  # 이 레포만 clone 한 사람은 훅을 켜는 방법을 알 길이 없다.
  cp "$KIT_ROOT/common/gate/VENDOR-README.md" "$vendor/README.md"
  rm -f "$vendor/gate/VENDOR-README.md"
  # 고르지 않은 언어의 어댑터는 vendor 하지 않는다 — 설치 뒤에 지우면
  # 체크섬이 어긋나 CI 가 "손으로 고쳤다" 로 죽는다.
  for _l in $(echo "$DROP" | tr ',' ' '); do rm -f "$vendor/gate/adapters/$_l.sh"; done
  chmod +x "$vendor"/gate/*.sh "$vendor"/git-hooks/* 2>/dev/null
  # install-manifest 에 킷 커밋과 vendor 내용 체크섬을 함께 적는다.
  # 커밋만 적으면 파일을 손으로 고쳤을 때 버전 표시가 거짓말을 한다 —
  # 체크섬이 있으면 CI 가 재계산해서 드리프트를 잡을 수 있다.
  kit_rev=$( cd "$KIT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown )
  # 체크섬 계산은 vendor 된 lib.sh 의 정의를 쓴다 — CI 도 같은 함수를 부른다.
  # shellcheck source=/dev/null
  . "$vendor/gate/lib.sh"
  sum=$(gate_checksum "$vendor") || sum="no-hasher"
  # 해시만 적으면 어느 레포의 해시인지 알 수 없다. 원격 주소를 함께 적는다 —
  # 로컬 경로는 적지 않는다(머신마다 다르고 남의 파일 배치를 레포에 박는 것이다).
  kit_repo=$( git -C "$KIT_ROOT" remote get-url origin 2>/dev/null || echo "" )
  # 로컬 미러에서 clone 했으면 origin 이 경로다. 그것을 레포에 박지 않는다 —
  # 머신마다 다르고 남의 파일 배치를 알려주는 것 말고는 값이 없다.
  case "$kit_repo" in /*|"") kit_repo=$(basename "$KIT_ROOT") ;; esac
  # vendor 를 교체한 **직후** 쓴다. 나중으로 미루면 그 사이에 죽었을 때
  # 내용은 새 것 · checksum 은 옛 값이 되어 CI 가 "손으로 고쳤다" 로 오진한다.
  #
  # kit_rev 는 **출처 하나만** 뜻한다 — 어느 킷 커밋에서 왔나. 여기에 "충돌을
  # 어디까지 흡수했나" 를 겸하게 했더니, 프로젝트가 채운 CLAUDE.md 처럼 킷 원본과
  # 영원히 달라지는 파일에서 rev 가 동결돼 빠져나올 수 없었다(재현함).
  # 미해결 병합은 rev 로 추론하지 않고 **.ai-kit-new 가 실재하는지**로 본다.
  MANIFEST_REV_NEW="$kit_rev"
  printf 'kit_repo=%s\nkit_rev=%s\nchecksum=%s\nlangs=%s\n' \
    "$kit_repo" "$kit_rev" "$sum" "$LANGS" > "$vendor/install-manifest"
  # 항상 다시 복사하지만, 내용이 같으면 "바뀜" 이라고 말하지 않는다.
  if [ "${SUM_BEFORE:-}" = "$sum" ]; then
    NOOP+=(".ai-kit/ (게이트 vendor)")
  else
    INSTALLED+=(".ai-kit/ (게이트 vendor · $kit_rev · $sum · $LANGS)")
  fi

  fi

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 평가자가 레포를 받으면 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  # --dry-run 은 무엇이 바뀔지만 본다. git config 도 레포 상태이므로 건드리지 않는다.
  if [ "$(git -C "$TARGET" config core.hooksPath 2>/dev/null)" != ".ai-kit/git-hooks" ]; then
    [ "$DRY_RUN" = 1 ] || git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
    INSTALLED+=("core.hooksPath → .ai-kit/git-hooks (커밋되는 훅)")
  fi

  # 킷 클론의 경로를 이 레포의 로컬 git config 에 적는다 — 커밋되지 않는다.
  # SessionStart 훅이 이것으로 "설치된 킷이 낡았나" 를 판정한다. 커밋되는 파일에
  # 넣지 않는 이유: 머신마다 경로가 다르고, 남의 절대경로가 레포에 박히면
  # 그 사람 환경을 알려주는 것 말고는 아무 값도 없다.
  [ "$DRY_RUN" = 1 ] || git -C "$TARGET" config ai-kit.path "$KIT_ROOT" 2>/dev/null

  # 기존 .git/hooks 에 커스텀 훅이 있으면 알린다 — hooksPath 설정 시 무시된다.
  for h in pre-commit pre-push commit-msg; do
    f="$TARGET/.git/hooks/$h"
    [ -f "$f" ] && ! grep -q 'ai-kit' "$f" 2>/dev/null \
      && WARNINGS+=(".git/hooks/$h 가 있지만 core.hooksPath 설정으로 무시됩니다 — 필요하면 .ai-kit/git-hooks 로 옮기세요")
  done

  # ── 신원 고정 파일 시드 ──
  # 현재 실효 신원을 기대값으로 기록해두면, 이후 잘못된 신원 커밋을 훅이 막는다.
  eff_now=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$eff_now" ] && [ ! -f "$vendor/identity" ] && [ "$DRY_RUN" = 0 ]; then
    printf '# 이 레포에서 커밋할 이메일. pre-commit 훅이 검증한다.\n%s\n' "$eff_now" > "$vendor/identity"
    INSTALLED+=(".ai-kit/identity ($eff_now)")
  fi

  # ── git 신원 확인 ──
  # 기존 커밋의 author 와 실효 설정이 다르면 기여 이력이 갈라진다.
  # 기존 커밋의 저자와 현재 설정이 다르면 알린다. 다만 **다른 것이 정상인 경우가 많다**
  # — 남이 만든 레포에 초대받으면 첫 커밋은 당연히 남의 것이다. 그래서 "고쳐라" 가
  # 아니라 "이 값이 맞는지 확인하라" 로 묻고, 맞으면 할 일이 없다고 먼저 말한다.
  hist=$(git -C "$TARGET" log --format='%ae' 2>/dev/null | sort -u | head -3)
  eff=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$hist" ] && [ -n "$eff" ] && ! printf '%s\n' "$hist" | grep -qx "$eff"; then
    WARNINGS+=("이 레포에서 커밋할 이메일이 '$eff' 가 맞습니까?")
    WARNINGS+=("  맞으면 할 일 없습니다 — .ai-kit/identity 에 그 값으로 기록했고 훅이 그것을 검증합니다.")
    WARNINGS+=("  아니면: git config user.email '<쓸 이메일>' 후 .ai-kit/identity 를 지우고 다시 설치하세요.")
    WARNINGS+=("  (참고: 기존 커밋의 저자는 $(printf '%s ' $hist)입니다 — 남이 만든 레포라면 다른 것이 정상입니다.)")
  fi
fi

# ── 템플릿: 파일마다 목적지가 다르므로 명시적으로 매핑한다 ──
# 추측(전부 docs/ 로)하면 CLAUDE.md·PR 템플릿이 엉뚱한 데로 간다.
if [ "$DO_TEMPLATES" = 1 ]; then
  T="$KIT_ROOT/common/templates"
  place "$T/CLAUDE.md"                 "CLAUDE.md"
  place "$T/SPEC.md"                   "docs/SPEC.md"
  place "$T/traceability.md"           "docs/traceability.md"
  place "$T/dev-log.md"                "docs/dev-log.md"
  place "$T/RUNBOOK.md"                "docs/RUNBOOK.md"
  place "$T/adr.md"                    "docs/adr/0000-template.md"
  place "$T/plan.md"                   "docs/plan/0000-template.md"
  place "$T/PULL_REQUEST_TEMPLATE.md"  ".github/PULL_REQUEST_TEMPLATE.md"
  # 설계 근거 문서는 프로젝트와 함께 다녀야 한다 — CLAUDE.md 가 이것을 인용하는데
  # 킷 레포 경로로 가리키면 레포만 clone 한 사람은 따라갈 수 없다.
  # kit-guide 는 설치 직후 한 번 읽는 문서다. 나머지 설계 근거 문서와 같은 자리에 둔다.
  for d in "$KIT_ROOT"/common/docs/*.md; do
    [ -f "$d" ] || continue
    place "$d" "docs/process/$(basename "$d")"
  done
fi

if [ "$DO_LINT" = 1 ]; then
  # 게이트와 **같은 방식·같은 목록**으로 찾는다. 예전에는 여기서 backend/·frontend/ 라는
  # 디렉터리 이름을 가정했는데, 게이트는 마커 파일로 찾으므로 둘이 어긋났다 —
  # services/api/pyproject.toml 같은 구조에서 게이트는 ruff 를 돌리는데 킷 설정이
  # 그 자리에 없어 도구 기본값으로 돌았다. 찾은 자리마다 설정을 놓으면 이름을 몰라도 된다.
  #
  # 프룬 목록을 여기 복붙하지 않는다 — 두 벌이 되면 AI_KIT_PRUNE_DIRS 를 바꿨을 때
  # 게이트는 찾고 설치기는 못 찾는 상태가 된다. lib.sh 의 정의 하나를 함께 쓴다.
  # shellcheck source=/dev/null
  . "$KIT_ROOT/common/gate/lib.sh"

  # $4 는 선택 인자다 — set -u 하에서는 ${4:-} 로 받아야 미설정일 때 안 터진다.
  place_beside() { # $1=마커 $2=킷 설정 파일 $3=놓을 이름 $4=마커에 이 문자열이 있으면 건너뜀(선택)
    local marker dir rel skip="${4:-}"
    while IFS= read -r marker; do
      dir=$(dirname "$marker"); rel=${dir#./}; [ "$rel" = "." ] && rel=""
      # 프로젝트가 마커 안에 이미 설정을 갖고 있으면 두 벌을 만들지 않는다.
      if [ -n "$skip" ] && grep -q "$skip" "$TARGET/${rel:+$rel/}$(basename "$marker")" 2>/dev/null; then
        continue
      fi
      local dest="${rel:+$rel/}$3"
      # 같은 목적지를 이 실행에서 이미 처리했으면 건너뛴다.
      case " ${PLACED_DESTS:-} " in *" $dest "*) continue ;; esac
      PLACED_DESTS="${PLACED_DESTS:-} $dest"
      place "$2" "$dest"
    # shellcheck disable=SC2046
    done < <(cd "$TARGET" && find . \( $(gate_prune_expr) \) -prune -o -name "$1" -print 2>/dev/null)
  }

  place_beside go.mod         "$KIT_ROOT/common/lint/go/.golangci.yml"    ".golangci.yml"
  place_beside package.json   "$KIT_ROOT/common/lint/ts/eslint.config.js" "eslint.config.js"
  # pyproject 에 [tool.ruff] 가 이미 있으면 그쪽이 설정이다 — 두 벌을 만들지 않는다.
  place_beside pyproject.toml "$KIT_ROOT/common/lint/py/ruff.toml"        "ruff.toml" \
    '^\[tool\.ruff'
  # JVM: 빌드 루트마다 .editorconfig.
  # 같은 목적지를 두 번 치지 않도록 막는다. settings.gradle + build.gradle 은 Gradle 의
  # 표준 배치라 한 디렉터리에 마커가 둘인 것이 정상이다. 같은 파일을 두 번 놓으면
  # 두 번째가 .ai-kit-new 를 만들어 없는 충돌을 보고한다.
  PLACED_EDITORCONFIG=""
  for m in settings.gradle settings.gradle.kts build.gradle build.gradle.kts pom.xml; do
    place_beside "$m" "$KIT_ROOT/common/lint/jvm/.editorconfig" ".editorconfig"
  done
  unset PLACED_EDITORCONFIG
fi

if [ "$DO_CI" = 1 ]; then
  for f in "$KIT_ROOT"/common/ci/*.yml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    # dependabot.yml 은 워크플로가 아니라 .github/ 루트에 있어야 인식된다.
    case "$b" in
      dependabot.yml) place "$f" ".github/$b" ;;
      gates.yml)
        # LANG_CHANGED 면 필터 결과가 달라지므로 킷 원본의 변경 여부로 판정하면 안 된다.
        # krel 을 비워 넘겨 "킷이 바꿨다" 로 취급한다 — DROP 이 비는(전 언어) 쪽도 같다.
        if [ -n "$DROP" ]; then
          tmp=$(mktemp) && awk -v drop="$DROP" -f "$KIT_ROOT/common/ci/filter-langs.awk" "$f" > "$tmp" \
            && place "$tmp" ".github/workflows/$b" \
                 "$( [ "$LANG_CHANGED" = 1 ] && echo "" || echo "common/ci/$b" )" \
            && rm -f "$tmp"
        elif [ "$LANG_CHANGED" = 1 ]; then
          place "$f" ".github/workflows/$b" ""
        else
          place "$f" ".github/workflows/$b"
        fi
        ;;
      *)              place "$f" ".github/workflows/$b" ;;
    esac
  done
fi

# ── Claude Code 설정: 목적지가 다르다. README 같은 킷 문서는 설치하지 않는다. ──
if [ "$DO_AGENT" = 1 ]; then
  cc="$KIT_ROOT/claude-code"
  while IFS= read -r f; do
    rel=${f#"$cc"/}
    [ "$rel" = "README.md" ] && continue
    place "$f" ".claude/$rel"
  done < <(find "$cc" -type f)
fi

# ── 원격 변경: 브랜치 보호 ──
# **지난** 실행이 남긴 병합거리. 이번 실행이 방금 만든 것은 아래 충돌 절에 나오므로
# 여기서 또 적지 않는다 — 같은 말이 두 번 나오면 둘 다 안 읽힌다.
STALE=()
while IFS= read -r leftover; do
  rel=${leftover#"$TARGET/"}; base=${rel%.ai-kit-new}
  case " ${CONFLICTS[*]:-} " in *" $base "*) continue ;; esac
  STALE+=("$base")
done < <(find "$TARGET" -name '*.ai-kit-new' -not -path '*/.git/*' 2>/dev/null)

if [ "$DO_PROTECT" = 1 ]; then
  # protect-branch.sh 는 `gh repo view` 로 **현재 디렉터리**의 레포를 정한다.
  # cd 없이 부르면 킷 레포에 보호를 걸어버린다(원격 쓰기라 되돌리기도 번거롭다).
  if [ "$DRY_RUN" = 1 ]; then
    echo "install: --dry-run 이므로 브랜치 보호는 건드리지 않습니다"
  else
    if ! ( cd "$TARGET" && bash "$KIT_ROOT/common/ci/protect-branch.sh" ); then
      echo "install: 브랜치 보호 설정 실패" >&2
      PROTECT_FAILED=1
    fi
  fi
fi

# ── 보고 (산출물 규칙 R1: 개수만, 문제만 자세히) ──
[ "$DRY_RUN" = 1 ] && echo "── dry-run: 아무것도 바꾸지 않았습니다. 아래는 무엇이 바뀔지입니다 ──"
if [ "$DO_UPDATE" = 1 ]; then
  # 리비전 범위는 **이번 갱신 전체**의 성질이다. 개별 충돌에 붙일 것이 아니다.
  if [ -n "$KIT_REV" ] && [ -n "${MANIFEST_REV_NEW:-}" ] && [ "$KIT_REV" != "$MANIFEST_REV_NEW" ]; then
    echo "킷 갱신  $KIT_REV → $MANIFEST_REV_NEW"
  elif [ -z "$KIT_REV" ]; then
    echo "킷 갱신  (설치 시점 리비전을 알 수 없어 무엇이 바뀌었는지 대조하지 못했습니다)"
  fi
  echo "바뀜 ${#INSTALLED[@]}건 · 변경 없음 ${#NOOP[@]}건 · 확인 필요 ${#CONFLICTS[@]}건"
  if [ ${#INSTALLED[@]} -gt 0 ]; then echo ""; echo "킷 변경이 반영됨:"; printf '  %s\n' "${INSTALLED[@]}"; fi
else
echo "설치 ${#INSTALLED[@]}건 · 이미 있음 ${#NOOP[@]}건 · 확인 필요 ${#CONFLICTS[@]}건"
fi
if [ "$DO_HOOKS" = 1 ] && [ "$DO_UPDATE" = 0 ]; then
  cat <<'MSG'

── 설치기가 한 일 ──
  ✓ 게이트·훅을 .ai-kit/ 에 넣었습니다
  ✓ 훅을 켰습니다 (core.hooksPath → .ai-kit/git-hooks)

── 이제 할 일 ──
  1. .ai-kit/ 을 커밋하세요. 커밋하지 않으면 CI 도, 이 레포를 clone 한 사람도
     게이트를 갖지 못합니다.
  2. docs/process/kit-guide.md 를 읽으세요. 무엇이 자동으로 돌고, CLAUDE.md 에서
     무엇을 채워야 하고, 킷이 무엇을 안 하는지 적혀 있습니다.

── 참고 ──
  core.hooksPath 는 git 이 clone 에 담지 않는 로컬 설정입니다(보안상 의도된 동작).
  나중에 이 레포를 새로 clone 하는 사람은 한 줄이 필요합니다:

      git config core.hooksPath .ai-kit/git-hooks

  그래서 로컬 훅은 우회 가능한 '조기 피드백' 이고, 우회할 수 없는 강제는 CI 입니다.
  둘이 같은 gate.sh 를 부르는 이유가 그것입니다.
MSG
fi

if [ ${#CONFLICTS[@]} -gt 0 ]; then
  echo ""
  if [ "$DO_UPDATE" = 1 ]; then
    echo "확인 필요 — 이 레포가 고친 파일을 킷도 바꿨습니다. 기존 파일은 건드리지 않았고,"
    echo "킷의 새 버전은 같은 이름에 .ai-kit-new 를 붙여 옆에 두었습니다:"
  else
    echo "확인 필요 — 이미 있는 파일이라 덮지 않았습니다."
    echo "킷의 새 버전은 같은 이름에 .ai-kit-new 를 붙여 옆에 두었습니다:"
  fi
  printf '  %s\n' "${CONFLICTS[@]}"
  cat <<'MSG'

  둘을 비교해 **킷이 개선한 것만** 가져오고, 이 레포가 채운 내용은 그대로 두세요.
  끝나면 .ai-kit-new 를 지웁니다.

    diff CLAUDE.md CLAUDE.md.ai-kit-new

  에이전트에게 맡기려면 이렇게 시키세요:
    "*.ai-kit-new 를 각각 짝이 되는 원본과 비교해라. 킷이 개선한 것만 원본에
     반영하고, 이 프로젝트가 채운 내용은 건드리지 마라. 끝나면 .ai-kit-new 를 지워라."
MSG
fi
if [ ${#STALE[@]:-0} -gt 0 ]; then
  echo ""
  echo "지난 갱신에서 남은 것 — 아직 합치지 않았습니다(옆에 .ai-kit-new 가 있습니다):"
  printf '  %s\n' "${STALE[@]}"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""; echo "참고:"
  printf '  %s\n' "${WARNINGS[@]}"
fi

# 브랜치 보호는 원격 쓰기다. 실패했는데 0 으로 끝나면 부르는 쪽(merge-pr 스킬)이
# 보호가 걸렸다고 결론짓는다.
[ "$PROTECT_FAILED" = 1 ] && exit 1
exit 0
