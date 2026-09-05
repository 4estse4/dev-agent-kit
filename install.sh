#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh <프로젝트경로>      로컬 전부 (훅·템플릿·린트·CI·도구설정)
#                                        경로는 필수. 현재 위치면 "." 를 준다.
#   <kit>/install.sh <경로> [--lang py,ts] --hooks --lint   선택 설치
#   <kit>/install.sh --protect           GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#
#   <kit>/install.sh <경로> --dry-run    아무것도 바꾸지 않고 무엇이 달라질지만 본다
#
# .ai-kit/gate 와 git-hooks 는 킷 소유라 통째로 교체한다. 그 밖의 파일은 이미 있으면
# 건드리지 않고, 내용이 다르면 .ai-kit-new 로 옆에 둔다. **자동 병합은 하지 않는다** —
# 합치는 것은 사람·에이전트가 한다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 DO_AGENT=0 DRY_RUN=0 TARGET_ARG="" LANGS=""
# 설치할 항목을 고르지 않았으면 전부 설치한다.
# --lang·--dry-run 은 항목이 아니라 수식이므로 여기서 세지 않는다 —
# 세면 `install.sh <경로> --lang py` 가 아무것도 설치하지 않고 끝난다.
case " $* " in
  *" --hooks"*|*" --templates"*|*" --lint"*|*" --ci"*|*" --protect"*) ;;
  *) DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1 DO_AGENT=1 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    # 값을 받는 플래그는 값이 실제로 있는지 먼저 본다. 안 보면 `shift 2` 가 인자
    # 하나를 못 넘겨 실패하는데, 실패해도 루프는 계속 돌아 **같은 인자를 영원히
    # 다시 읽는다** — 출력 한 줄 없이 멈춘 것처럼 보인다(실측).
    --lang)
      [ $# -ge 2 ] || { echo "install: --lang 에 값이 필요합니다 (예: --lang py,ts)" >&2; exit 2; }
      LANGS="$2"; shift 2 ;;
    --lang=*) LANGS="${1#--lang=}"; shift ;;
    --protect) DO_PROTECT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    # 줄 번호를 박지 않는다 — 헤더가 길어지거나 짧아지면 그 숫자가 조용히 틀린다.
    # 실제로 그랬다: 갱신 절을 지우자 '2,16p' 가 코드까지 출력했다.
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
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

INSTALLED=(); SKIPPED=(); CONFLICTS=(); WARNINGS=()
# dry-run 은 대상 대신 이 트리에 놓는다. 놓고 나서 대상과 비교하면 무엇이 달라지는지가
# 나오고, 트리 자체가 남으므로 사람이나 에이전트가 그것을 보고 병합할 수 있다.
STAGE=""
# TMPDIR 은 끝에 / 가 붙어 온다(macOS). 값에서 떼지 않으면 출력 경로에 // 가 남는다 —
# 따옴표 자리를 옮기는 것으로는 안 없어진다.
_tmpdir=${TMPDIR:-/tmp}; _tmpdir=${_tmpdir%/}
# 실패를 그냥 넘기면 STAGE 가 빈 문자열이 되고, 그 뒤 모든 경로가 "/..." 가 된다 —
# 아무것도 안 바꾸겠다고 약속한 모드가 **파일시스템 루트에 쓰려고 든다.** 실측했다:
# 루트가 읽기 전용이라 막혔을 뿐이고, 쓸 수 있는 환경이면 그대로 썼다.
if [ "$DRY_RUN" = 1 ]; then
  STAGE=$(mktemp -d "$_tmpdir/ai-kit-dryrun.XXXXXX") || {
    echo "install: 임시 디렉터리를 만들지 못했습니다 — $_tmpdir" >&2
    echo "  dry-run 은 킷이 놓을 파일을 거기에 만들어 이 레포와 대조합니다. 없으면 할 수 없습니다." >&2
    exit 1; }
fi
ALL_LANGS="go ts jvm py"
# --lang 을 안 주면 설치 당시 선택을 이어받는다 — 안 그러면 재설치가 조용히
# 언어를 도로 넣어, 고르지 않은 언어의 잡이 CI 에 되살아난다.
STAMP="$TARGET/.ai-kit/install-manifest"
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
DROP=""
for _l in $ALL_LANGS; do
  case ",$LANGS," in *",$_l,"*) ;; *) DROP="${DROP:+$DROP,}$_l" ;; esac
done

# 기존 파일을 보존하며 복사한다.
#
# 판정은 dry-run 이든 아니든 **똑같이** 한다. 다르게 하면 dry-run 이 예고한 것과
# 실제 설치가 갈리고, 그러면 예고를 읽을 이유가 없어진다. 다른 것은 쓰기뿐이다.
# mkdir 도 쓰기다 — 조건 앞에 두면 dry-run 이 빈 디렉터리를 남긴다.
place() { # $1=src $2=dst(대상 레포 상대)
  local src="$1" dst="$TARGET/$2"
  # dry-run 은 대상에 쓰지 않고 STAGE 에 놓는다. 판정(아래)은 그대로 돈다.
  if [ "$DRY_RUN" = 1 ]; then mkdir -p "$STAGE/$(dirname "$2")"; cp "$src" "$STAGE/$2"; fi
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then SKIPPED+=("$2 (동일)"); return; fi
    [ "$DRY_RUN" = 1 ] || cp "$src" "$dst.ai-kit-new"
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
  # .ai-kit/gate 와 git-hooks 는 킷 소유라 통째로 교체한다. identity 는 그 아래
  # 살지만 킷 소유가 아니므로 남긴다.
  kit_rev=$( cd "$KIT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown )
  # 설치와 dry-run 이 **같은 함수**를 쓴다. 두 벌로 두면 dry-run 이 예고하는 내용과
  # 설치가 놓는 내용이 갈리고, 갈렸을 때 알아챌 방법이 없다.
  vendor_into() { # $1=목적지 .ai-kit 디렉터리
    local v="$1"
    rm -rf "$v/gate" "$v/git-hooks" "$v/README.md"
    mkdir -p "$v"
    cp -R "$KIT_ROOT/common/gate" "$KIT_ROOT/common/git-hooks" "$v/"
    # 활성화 절차가 레포 안에 있어야 한다 — install.sh 는 킷 레포에만 있으므로
    # 이 레포만 clone 한 사람은 훅을 켜는 방법을 알 길이 없다.
    cp "$KIT_ROOT/common/gate/VENDOR-README.md" "$v/README.md"
    rm -f "$v/gate/VENDOR-README.md"
    # 고르지 않은 언어의 어댑터는 vendor 하지 않는다.
    for _l in $(echo "$DROP" | tr ',' ' '); do rm -f "$v/gate/adapters/$_l.sh"; done
    chmod +x "$v"/gate/*.sh "$v"/git-hooks/* 2>/dev/null
    # install-manifest 는 **어디서 왔는지**만 적는다 — 킷 커밋과 언어 선택.
    # 내용 체크섬은 두지 않는다. 이 레포에서 게이트를 고치는 것이 정상 작업인데
    # (.ai-kit/README.md), 체크섬을 두면 그 정상 작업이 CI 를 빨갛게 만들고,
    # 빨간 것을 푸는 안내(install.sh 재실행)가 그 수정을 말없이 지운다. 실측했다.
    # 무엇이 달라졌는지는 --dry-run 이 보여준다.
    printf 'kit_rev=%s\nlangs=%s\n' "$kit_rev" "$LANGS" > "$v/install-manifest"
  }
  if [ "$DRY_RUN" = 1 ]; then vendor_into "$STAGE/.ai-kit"; else vendor_into "$vendor"; fi
  # 보고는 dry-run 에서도 한다 — 안 그러면 예고한 건수와 실제 건수가 갈린다.
  INSTALLED+=(".ai-kit/ (게이트 vendor · $kit_rev · $LANGS)")

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 평가자가 레포를 받으면 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  [ "$DRY_RUN" = 1 ] || git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
  INSTALLED+=("core.hooksPath → .ai-kit/git-hooks (커밋되는 훅)")

  # 킷 클론의 경로를 이 레포의 로컬 git config 에 적는다 — 커밋되지 않는다.
  # SessionStart 훅이 이것으로 "설치된 킷이 낡았나" 를 판정한다. 커밋되는 파일에
  # 넣지 않는 이유: 머신마다 경로가 다르고, 남의 절대경로가 레포에 박히면
  # 그 사람 환경을 알려주는 것 말고는 아무 값도 없다.
  [ "$DRY_RUN" = 1 ] || git -C "$TARGET" config ai-kit.path "$KIT_ROOT" 2>/dev/null

  # 옛 킷의 gates.yml 은 vendored 잡에서 gate_checksum 을 부른다. 그 함수는 이제
  # lib.sh 에 없다. gates.yml 은 프로젝트 소유라 install.sh 가 덮지 않으므로,
  # ".ai-kit 만 새것 + 워크플로는 옛것" 이 재설치의 **기본 경로**다. 그대로 두면
  # CI 가 `gate_checksum: command not found` 로 종료코드 127 에 죽는다(실측).
  _wf="$TARGET/.github/workflows/gates.yml"
  if [ -f "$_wf" ] && grep -q 'gate_checksum' "$_wf" 2>/dev/null; then
    WARNINGS+=(".github/workflows/gates.yml 이 gate_checksum 을 부르는데 이 킷의 lib.sh 에는 그 함수가 없습니다 — CI 가 종료코드 127 로 실패합니다.")
    WARNINGS+=("  그 워크플로의 '체크섬 재계산' 블록을 지우세요. 킷의 새 버전은 common/ci/gates.yml 에 있고, 충돌로 옆에 놓였다면 .github/workflows/gates.yml.ai-kit-new 입니다.")
  fi

  # 기존 .git/hooks 에 커스텀 훅이 있으면 알린다 — hooksPath 설정 시 무시된다.
  for h in pre-commit pre-push commit-msg; do
    f="$TARGET/.git/hooks/$h"
    [ -f "$f" ] && ! grep -q 'ai-kit' "$f" 2>/dev/null \
      && WARNINGS+=(".git/hooks/$h 가 있지만 core.hooksPath 설정으로 무시됩니다 — 필요하면 .ai-kit/git-hooks 로 옮기세요")
  done

  # ── 신원 고정 파일 시드 ──
  # 현재 실효 신원을 기대값으로 기록해두면, 이후 잘못된 신원 커밋을 훅이 막는다.
  eff_now=$(git -C "$TARGET" config user.email 2>/dev/null)
  if [ -n "$eff_now" ]; then
    if [ -f "$vendor/identity" ]; then
      # 이미 있으면 건너뛴 것으로 **센다**. 아예 세지 않으면 첫 설치와 재설치의
      # 합계가 달라지고, 읽는 사람은 무엇이 빠졌는지 알 길이 없다.
      SKIPPED+=(".ai-kit/identity (이미 있음)")
    else
      if [ "$DRY_RUN" = 1 ]; then
        printf '# 이 레포에서 커밋할 이메일. pre-commit 훅이 검증한다.\n%s\n' "$eff_now" > "$STAGE/.ai-kit/identity"
      else
        printf '# 이 레포에서 커밋할 이메일. pre-commit 훅이 검증한다.\n%s\n' "$eff_now" > "$vendor/identity"
      fi
      INSTALLED+=(".ai-kit/identity ($eff_now)")
    fi
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
  # 같은 목적지를 두 번 치지 않도록 place_beside 의 PLACED_DESTS 가 막는다.
  # settings.gradle + build.gradle 은 Gradle 의 표준 배치라 한 디렉터리에 마커가
  # 둘인 것이 정상이고, 그때 .editorconfig 를 두 번 놓으면 두 번째가 충돌로 잡힌다.
  for m in settings.gradle settings.gradle.kts build.gradle build.gradle.kts pom.xml; do
    place_beside "$m" "$KIT_ROOT/common/lint/jvm/.editorconfig" ".editorconfig"
  done
fi

if [ "$DO_CI" = 1 ]; then
  for f in "$KIT_ROOT"/common/ci/*.yml; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    # dependabot.yml 은 워크플로가 아니라 .github/ 루트에 있어야 인식된다.
    case "$b" in
      dependabot.yml) place "$f" ".github/$b" ;;
      gates.yml)
        if [ -n "$DROP" ]; then
          tmp=$(mktemp) && awk -v drop="$DROP" -f "$KIT_ROOT/common/ci/filter-langs.awk" "$f" > "$tmp" \
            && place "$tmp" ".github/workflows/$b" && rm -f "$tmp"
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
if [ "$DO_PROTECT" = 1 ]; then
  bash "$KIT_ROOT/common/ci/protect-branch.sh" || echo "install: 브랜치 보호 설정 실패" >&2
fi

# ── dry-run 보고: 무엇이 달라지는지 ──
#
# 건수만 세면 "충돌 3건" 까지만 알고 무엇이 왜 다른지는 모른다. 그래서 킷이 놓을
# 트리(STAGE)를 대상과 대조해 파일별로 분류하고 diff 를 붙인다. 병합은 하지 않는다 —
# 트리를 남겨두고 사람이나 에이전트가 보고 정한다.
DIFF_MAX_LINES=${AI_KIT_DIFF_MAX_LINES:-60}   # 파일당
DIFF_MAX_TOTAL=${AI_KIT_DIFF_MAX_TOTAL:-400}  # 전체

dryrun_report() {
  local n_new=0 n_diff=0 n_same=0 n_gone=0
  local list_new="" list_diff="" list_gone="" rel f
  while IFS= read -r f; do
    rel=${f#"$STAGE"/}
    if [ ! -e "$TARGET/$rel" ]; then
      n_new=$((n_new + 1)); list_new="${list_new}  + ${rel}"$'\n'
    elif cmp -s "$f" "$TARGET/$rel"; then
      n_same=$((n_same + 1))
    else
      n_diff=$((n_diff + 1)); list_diff="${list_diff}  ~ ${rel}"$'\n'
    fi
  done < <(find "$STAGE" -type f | LC_ALL=C sort)

  # 킷 소유 자리(.ai-kit 전체)에서만 "사라질 것" 을 본다. 그 밖은 프로젝트 소유라
  # 킷이 놓지 않는 것이 정상이고, 거기까지 세면 프로젝트 파일 전부가 목록에 뜬다.
  #
  # gate·git-hooks 만 보지 않고 .ai-kit 전체를 보는 이유: 옛 킷이 두고 간 것이
  # 그 둘 밖에 쌓인다. 실제로 baseline/ 29파일이 그렇게 남았고, 좁게 보면 안 보인다.
  # identity 는 예외다 — 킷 소유가 아니고, 커밋 신원이 비면 STAGE 에 안 놓인다.
  if [ -d "$TARGET/.ai-kit" ]; then
    while IFS= read -r f; do
      rel=${f#"$TARGET"/}
      [ "$rel" = ".ai-kit/identity" ] && continue
      [ -e "$STAGE/$rel" ] || { n_gone=$((n_gone + 1)); list_gone="${list_gone}  - ${rel}"$'\n'; }
    done < <(find "$TARGET/.ai-kit" -type f | LC_ALL=C sort)
  fi

  echo "── dry-run: 아무것도 바꾸지 않았습니다 ──"
  echo ""
  echo "지금 설치하면 — 새 파일 ${n_new} · 내용이 다름 ${n_diff} · 그대로 ${n_same} · 킷이 안 놓음 ${n_gone}"
  [ -n "$list_diff" ] && { echo ""; echo "내용이 다름"; printf '%s' "$list_diff"; }
  [ -n "$list_new" ]  && { echo ""; echo "새 파일";     printf '%s' "$list_new"; }
  [ -n "$list_gone" ] && { echo ""; echo "킷이 안 놓음 (이 레포에만 있는 킷 소유 파일)"; printf '%s' "$list_gone"; }

  # diff 는 "이 레포 → 킷" 방향이다. - 가 지금 있는 것, + 가 킷이 놓을 것.
  if [ -n "$list_diff" ]; then
    local shown=0 body cut
    echo ""
    echo "diff (- 지금 이 레포 / + 킷이 놓을 것)"
    while IFS= read -r rel; do
      rel=${rel#  ~ }
      [ -n "$rel" ] || continue
      [ "$shown" -ge "$DIFF_MAX_TOTAL" ] && { echo ""; echo "  … 전체 상한 ${DIFF_MAX_TOTAL}줄에 걸려 나머지는 생략했습니다. 병합용 트리에서 직접 보세요."; break; }
      echo ""
      echo "──── $rel"
      body=$(diff -u "$TARGET/$rel" "$STAGE/$rel" 2>/dev/null | tail -n +3)
      if [ -z "$body" ]; then echo "  (텍스트 diff 없음 — 바이너리이거나 권한만 다릅니다)"; continue; fi
      cut=$(printf '%s\n' "$body" | wc -l | tr -d " ")
      printf '%s\n' "$body" | head -n "$DIFF_MAX_LINES" | sed 's/^/  /'
      [ "$cut" -gt "$DIFF_MAX_LINES" ] && echo "  … 이 파일에서 $((cut - DIFF_MAX_LINES))줄 더 있습니다"
      # 상한은 **찍은 줄**로 센다. diff 전체 길이로 세면 잘려서 안 보인 줄까지 한도를
      # 먹어, "400줄에 걸렸다" 고 말하면서 실제로는 그보다 훨씬 적게 보여준다.
      if [ "$cut" -gt "$DIFF_MAX_LINES" ]; then shown=$((shown + DIFF_MAX_LINES)); else shown=$((shown + cut)); fi
    done <<< "$list_diff"
  fi

  echo ""
  echo "병합용 트리: $STAGE"
  echo "  킷이 놓을 파일만 들어 있습니다. 파일별로 비교하려면:"
  echo "      diff -u <파일> $STAGE/<파일>"
  echo "  임시 디렉터리이므로 정리 정책에 사라질 수 있습니다. 남길 것은 옮겨두세요."
}

# ── 보고 (산출물 규칙 R1: 개수만, 문제만 자세히) ──
if [ "$DRY_RUN" = 1 ]; then
  dryrun_report
else
echo "설치 ${#INSTALLED[@]}건 · 건너뜀 ${#SKIPPED[@]}건 · 충돌 ${#CONFLICTS[@]}건 · 확인필요 ${#WARNINGS[@]}건"
fi
if [ "$DO_HOOKS" = 1 ] && [ "$DRY_RUN" = 0 ]; then
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

if [ ${#CONFLICTS[@]} -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
  echo ""
  echo "충돌 — 기존 파일을 보존했고 새 것은 .ai-kit-new 로 옆에 뒀습니다. 확인 후 병합하세요:"
  printf '  %s\n' "${CONFLICTS[@]}"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""; echo "확인 필요:"
  printf '  %s\n' "${WARNINGS[@]}"
fi
