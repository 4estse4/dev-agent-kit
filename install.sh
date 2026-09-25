#!/usr/bin/env bash
# 대상 레포에 킷을 설치한다. 대상 레포 안에서 실행한다.
#
#   <kit>/install.sh <프로젝트경로>      로컬 전부 (훅·템플릿·린트·CI·도구설정)
#                                        경로는 필수. 현재 위치면 "." 를 준다.
#   <kit>/install.sh <경로> [--lang py,ts] --hooks --lint   선택 설치
#     항목: --hooks --templates --lint --ci --agent  (--agent 는 .claude/** 와 docs/process/**)
#   <kit>/install.sh <경로> --protect    GitHub 브랜치 보호 설정 (원격 변경 — 별도 플래그)
#
#   <kit>/install.sh <경로> --dry-run    아무것도 바꾸지 않고 무엇이 달라질지만 본다
#
# 킷 소유는 .ai-kit/** 와 .claude/{skills,agents,hooks}/** 와 docs/process/** 다 —
# 재설치가 **덮는다.** 프로젝트 소유는 CLAUDE.md 와 .claude/settings.json 이고, 이미
# 있으면 건드리지 않고 내용이 다르면 .ai-kit-new 로 옆에 둔다. **자동 병합은 하지
# 않는다** — 합치는 것은 사람·에이전트가 한다. 무엇이 덮이는지는 --dry-run 이 보여준다.
set -uo pipefail

KIT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

DO_HOOKS=0 DO_TEMPLATES=0 DO_LINT=0 DO_CI=0 DO_PROTECT=0 DO_AGENT=0 DRY_RUN=0 TARGET_ARG="" LANGS=""
# 설치할 항목을 고르지 않았으면 전부 설치한다.
# --lang·--dry-run 은 항목이 아니라 수식이므로 여기서 세지 않는다 —
# 세면 `install.sh <경로> --lang py` 가 아무것도 설치하지 않고 끝난다.
case " $* " in
  *" --hooks"*|*" --templates"*|*" --lint"*|*" --ci"*|*" --protect"*|*" --agent"*) ;;
  *) DO_HOOKS=1 DO_TEMPLATES=1 DO_LINT=1 DO_CI=1 DO_AGENT=1 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --hooks) DO_HOOKS=1; shift ;;
    --templates) DO_TEMPLATES=1; shift ;;
    --lint) DO_LINT=1; shift ;;
    --ci) DO_CI=1; shift ;;
    --agent) DO_AGENT=1; shift ;;
    # 값을 받는 플래그는 값이 실제로 있는지 먼저 본다. 안 보면 `shift 2` 가 인자
    # 하나를 못 넘겨 실패하는데, 실패해도 루프는 계속 반복되어 **같은 인자를 영원히
    # 다시 읽는다** — 출력 한 줄 없이 멈춘 것처럼 보인다(실제로 확인함).
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

PROTECT_SKIPPED=0
INSTALLED=(); REPLACED=(); DELETED=(); SKIPPED=(); CONFLICTS=(); WARNINGS=()
# dry-run 은 대상 대신 이 트리에 놓는다. 놓고 나서 대상과 비교하면 무엇이 달라지는지가
# 나오고, 트리 자체가 남으므로 사람이나 에이전트가 그것을 보고 병합할 수 있다.
STAGE=""
# TMPDIR 은 끝에 / 가 붙어 온다(macOS). 값에서 떼지 않으면 출력 경로에 // 가 남는다 —
# 따옴표 자리를 옮기는 것으로는 안 없어진다.
_tmpdir=${TMPDIR:-/tmp}; _tmpdir=${_tmpdir%/}
# 실패를 그냥 넘기면 STAGE 가 빈 문자열이 되고, 그 뒤 모든 경로가 "/..." 가 된다 —
# 아무것도 안 바꾸겠다고 약속한 모드가 **파일시스템 루트에 쓰려고 든다.** 실제로 확인했다:
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
  # dry-run 은 대상에 쓰지 않고 STAGE 에 놓는다. 판정(아래)은 그대로 실행된다.
  if [ "$DRY_RUN" = 1 ]; then mkdir -p "$STAGE/$(dirname "$2")"; cp "$src" "$STAGE/$2"; fi
  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then SKIPPED+=("$2 (동일)"); return; fi
    [ "$DRY_RUN" = 1 ] || cp "$src" "$dst.ai-kit-new"
    CONFLICTS+=("$2"); return
  fi
  [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
  INSTALLED+=("$2")
}

# 킷 소유 자리는 **덮는다.** place() 와 갈리는 지점이 여기다.
#
# 왜 스킬·에이전트·훅이 킷 소유인가: 안 덮으면 갱신이 무의미하다. 그것들은 킷이 계속
# 고치는 물건이고, 프로젝트가 손댈 이유가 없다(손댈 것은 settings.json 과 CLAUDE.md 다).
# 실제로 안 덮은 결과가 이렇다 — 한 프로젝트가 여덟 달 전 판으로 리뷰를 일곱 라운드
# 진행했고, 그 옛 판은 지금 킷이 없애려는 바로 그 동작을 시키고 있었다.
#
# **프로젝트가 만든 파일은 손대지 않는다.** 이 함수는 킷이 배포하는 파일만 순회하므로
# 그 목록에 없는 것은 애초에 닿지 않는다. 지우지도 않는다.
replace() { # $1=src $2=dst(대상 레포 상대)
  local src="$1" dst="$TARGET/$2" had=0
  if [ "$DRY_RUN" = 1 ]; then mkdir -p "$STAGE/$(dirname "$2")"; cp "$src" "$STAGE/$2"; fi
  if [ -e "$dst" ]; then
    cmp -s "$src" "$dst" && { SKIPPED+=("$2 (동일)"); return; }
    had=1
  fi
  [ "$DRY_RUN" = 1 ] || { mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; }
  if [ "$had" = 1 ]; then REPLACED+=("$2"); else INSTALLED+=("$2"); fi
}

# ── 게이트 vendor: 대상 레포에 .ai-kit/ 로 복사한다 ──
# 홈 디렉터리 경로를 훅·CI 에 박으면 다른 머신과 CI 에서 깨진다.
# vendor 해서 레포에 커밋하면 어디서 clone 해도 같은 게이트가 실행된다.
if [ "$DO_HOOKS" = 1 ]; then
  vendor="$TARGET/.ai-kit"
  # .ai-kit/gate 와 git-hooks 는 킷 소유라 통째로 교체한다. identity 는 그 아래
  # 살지만 킷 소유가 아니므로 남긴다.
  kit_rev=$( cd "$KIT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown )
  # 설치와 dry-run 이 **같은 함수**를 쓴다. 두 벌로 두면 dry-run 이 예고하는 내용과
  # 설치가 놓는 내용이 갈리고, 갈렸을 때 알아챌 방법이 없다.
  vendor_into() { # $1=목적지 .ai-kit 디렉터리
    local v="$1"
    # .ai-kit 은 identity 를 빼면 전부 킷 소유다. 소유한 자리는 **통째로 비우고 놓는다** —
    # 이름을 지목해 지우면 그 목록이 킷이 바뀔 때마다 자라고, 자라다 빠진다.
    # 무엇이 사라지는지는 --dry-run 의 "재설치가 지울 것" 이 미리 보여준다.
    if [ -d "$v" ]; then
      find "$v" -mindepth 1 -maxdepth 1 ! -name identity -exec rm -rf {} +
    fi
    mkdir -p "$v"
    cp -R "$KIT_ROOT/common/gate" "$KIT_ROOT/common/git-hooks" "$v/"
    # 활성화 절차가 레포 안에 있어야 한다 — install.sh 는 킷 레포에만 있으므로
    # 이 레포만 clone 한 사람은 훅을 켜는 방법을 알 길이 없다.
    cp "$KIT_ROOT/common/gate/VENDOR-README.md" "$v/README.md"
    rm -f "$v/gate/VENDOR-README.md"
    # 고르지 않은 언어의 어댑터는 vendor 하지 않는다.
    for _l in $(echo "$DROP" | tr ',' ' '); do rm -f "$v/gate/adapters/$_l.sh"; done
    chmod +x "$v"/gate/*.sh "$v"/git-hooks/* 2>/dev/null
    # identity 는 킷 소유가 아니다. 실제 설치는 위 rm 이 건너뛰어 그대로 두고, dry-run 은
    # 대상의 것을 가져온다. **두 모드가 같은 최종 트리를 만들어야** 삭제 집계가 갈리지
    # 않는다 — 이 복사가 집계보다 뒤에 있었을 때 dry-run 이 identity 를 삭제로 셌다.
    [ "$v" = "$TARGET/.ai-kit" ] || [ ! -f "$TARGET/.ai-kit/identity" ] \
      || cp "$TARGET/.ai-kit/identity" "$v/identity"
    # install-manifest 는 **어디서 왔는지**만 적는다 — 킷 커밋과 언어 선택.
    # 내용 체크섬은 두지 않는다. 이 레포에서 게이트를 고치는 것이 정상 작업인데
    # (.ai-kit/README.md), 체크섬을 두면 그 정상 작업이 CI 를 빨갛게 만들고,
    # 빨간 것을 푸는 안내(install.sh 재실행)가 그 수정을 말없이 지운다. 실제로 확인했다.
    # 무엇이 달라졌는지는 --dry-run 이 보여준다.
    printf 'kit_rev=%s\nlangs=%s\n' "$kit_rev" "$LANGS" > "$v/install-manifest"
  }
  # 요약 집계 — vendor 는 cp -R 로 한 번에 옮기므로 place()/replace() 를 안 지난다.
  # 한 줄로 "설치 1건" 이라고만 세면 요약이 실제와 갈린다: 6개를 교체하고도 "교체 0건"
  # 이라고 말한 적이 있다(실제로 확인함). dry-run 은 파일마다 세므로 예고와 실제가 어긋난다.
  # **옮기기 전에** 대상의 현재 상태로 센다.
  while IFS= read -r _s; do
    _r=".ai-kit/${_s#"$KIT_ROOT"/common/}"
    case "$_r" in
      .ai-kit/gate/VENDOR-README.md) _r=".ai-kit/README.md" ;;
      .ai-kit/gate/adapters/*)
        _l=$(basename "$_s" .sh)
        case ",$DROP," in *",$_l,"*) continue ;; esac ;;
    esac
    if [ ! -e "$TARGET/$_r" ];        then INSTALLED+=("$_r")
    elif cmp -s "$_s" "$TARGET/$_r";  then SKIPPED+=("$_r (동일)")
    else                                   REPLACED+=("$_r"); fi
  done < <(find "$KIT_ROOT/common/gate" "$KIT_ROOT/common/git-hooks" -type f)
  # install-manifest 는 킷 소스에 없고 vendor_into() 가 만든다. 위 루프가 안 걷으므로
  # 여기서 센다 — 안 그러면 **첫 설치에서만** 예고가 실제보다 하나 크다(재설치에서는
  # identity 와 상쇄돼 우연히 맞아 안 드러난다).
  if [ ! -e "$TARGET/.ai-kit/install-manifest" ]; then INSTALLED+=(".ai-kit/install-manifest")
  elif [ "$(printf 'kit_rev=%s\nlangs=%s\n' "$kit_rev" "$LANGS")" = "$(cat "$TARGET/.ai-kit/install-manifest" 2>/dev/null)" ]; then
    SKIPPED+=(".ai-kit/install-manifest (동일)")
  else REPLACED+=(".ai-kit/install-manifest"); fi

  # 삭제도 센다. vendor_into() 가 .ai-kit 을 통째로 비우므로 킷이 다시 놓지 않는 파일은
  # 사라지는데, 실제 실행이 그것을 한 줄도 말하지 않은 적이 있다(실제로 확인함: 다섯 칸이 전부
  # 0인데 파일이 사라졌다).
  #
  # **정렬해서 비교하지 않는다.** 설치 전 목록의 각 항목이 최종 트리에 아직 있는지만
  # 본다. sort 와 comm 을 쓰면 정렬 기준이 둘이 되고 — sort 는 LC_ALL=C, comm 은 세션
  # 로케일 — en_US.UTF-8 은 대소문자를 1차 비교에서 무시하므로 `.ai-kit/README.md` 하나로
  # 병합이 어긋나 **안 지운 pre-commit·pre-push 를 지웠다고 보고했다**(실제로 확인함).
  # 존재 검사에는 정렬 기준이 없다.
  #
  # **경로 규칙도 다시 적지 않는다.** 한 번은 `common/` 아래 존재 여부로 판정하게 적었다가
  # dry-run 과 갈렸다 — `common/` 에는 vendor 가 안 가져오는 ci·docs·templates 도 있어서
  # `.ai-kit/ci/*` 가 "킷이 놓는 것" 으로 오판돼 무보고 삭제됐다(실제로 확인함: `삭제 0건` 인데
  # 셋이 사라졌다). 근거가 하나면 갈릴 수 없다.
  _before=$( cd "$TARGET" 2>/dev/null && find .ai-kit -type f 2>/dev/null )

  if [ "$DRY_RUN" = 1 ]; then vendor_into "$STAGE/.ai-kit"; _final="$STAGE"
  else                        vendor_into "$vendor";        _final="$TARGET"; fi
  while IFS= read -r _g; do
    [ -n "$_g" ] && [ ! -e "$_final/$_g" ] && DELETED+=("$_g")
  done <<< "$_before"
  # dryrun_report() 가 이 배열을 그대로 「재설치가 지울 것」으로 쓴다. 거기서 다시 세면
  # 두 벌이 되고, 두 벌은 반드시 서로 달라진다 — 위 주석에 적은 실제 사례 둘이 그것이다.
  # 보고는 dry-run 에서도 한다 — 안 그러면 예고한 건수와 실제 건수가 갈린다.

  # 훅은 .git/hooks 에 두지 않는다 — 그 디렉터리는 clone 되지 않으므로
  # 레포를 새로 받은 사람에게는 강제가 통째로 사라진다.
  # 대신 커밋되는 .ai-kit/git-hooks/ 를 core.hooksPath 로 가리킨다.
  [ "$DRY_RUN" = 1 ] || git -C "$TARGET" config core.hooksPath .ai-kit/git-hooks
  # core.hooksPath 는 파일이 아니라 설정이다. 파일 건수에 섞으면 dry-run(파일을 센다)과
  # 실제 실행의 숫자가 갈린다. 아래 "설치기가 한 일" 에서 따로 보고한다.

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
  if [ -n "$eff_now" ]; then
    if [ -f "$vendor/identity" ]; then
      # 이미 있으면 건너뛴 것으로 **센다**. 아예 세지 않으면 첫 설치와 재설치의
      # 합계가 달라지고, 읽는 사람은 무엇이 빠졌는지 알 길이 없다.
      # (STAGE 로 옮기는 것은 vendor_into() 가 한다 — 여기서 또 하면 두 벌이 된다.)
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
# ── 문서: 킷 소유. 정의가 이 문서의 절을 이름으로 가리키므로 **정의와 짝이다.**
# 그래서 --agent 로도 갱신된다. 안 그러면 정의만 새것이 되어 없는 절을 부른다(실제로 확인함).
# --templates 로도 갱신된다 — 처음 설치할 때 문서가 같이 와야 한다.
if [ "$DO_AGENT" = 1 ] || [ "$DO_TEMPLATES" = 1 ]; then
  # 프로젝트가 자기 사정을 적을 자리는 CLAUDE.md 이지 이 문서들이 아니다. 스킬·에이전트 정의가 이 문서의 절을 이름으로 가리키는데,
  # 정의만 갱신되고 문서가 보존되면 **업그레이드마다 끊긴 참조가 확정으로 생긴다.**
  # 실제로 그랬다 — 한 레포에서 콜드 리뷰어 정의가 읽으라는 절이 그 레포 문서에 없었다.
  # 프로젝트가 자기 사정을 적을 자리는 CLAUDE.md 이지 이 문서들이 아니다.
  for d in "$KIT_ROOT"/common/docs/*.md; do
    [ -f "$d" ] || continue
    replace "$d" "docs/process/$(basename "$d")"
  done
fi

if [ "$DO_TEMPLATES" = 1 ]; then
  T="$KIT_ROOT/common/templates"
  place "$T/CLAUDE.md"                 "CLAUDE.md"
  place "$T/SPEC.md"                   "docs/SPEC.md"
  place "$T/traceability.md"           "docs/traceability.md"
  place "$T/dev-log.md"                "docs/dev-log.md"
  place "$T/RUNBOOK.md"                "docs/RUNBOOK.md"
  place "$T/adr.md"                    "docs/adr/0000-template.md"
  place "$T/plan.md"                   "docs/plan/0000-template.md"
  place "$T/plan-README.md"            "docs/plan/README.md"
  place "$T/PULL_REQUEST_TEMPLATE.md"  ".github/PULL_REQUEST_TEMPLATE.md"
  # 설계 근거 문서는 프로젝트와 함께 다녀야 한다 — CLAUDE.md 가 이것을 인용하는데
  # 킷 레포 경로로 가리키면 레포만 clone 한 사람은 따라갈 수 없다.
  # kit-guide 는 설치 직후 한 번 읽는 문서다. 나머지 설계 근거 문서와 같은 자리에 둔다.
fi

if [ "$DO_LINT" = 1 ]; then
  # 게이트와 **같은 방식·같은 목록**으로 찾는다. 예전에는 여기서 backend/·frontend/ 라는
  # 디렉터리 이름을 가정했는데, 게이트는 마커 파일로 찾으므로 둘이 어긋났다 —
  # services/api/pyproject.toml 같은 구조에서 게이트는 ruff 를 실행하는데 킷 설정이
  # 그 자리에 없어 도구 기본값으로 실행됐다. 찾은 자리마다 설정을 놓으면 이름을 몰라도 된다.
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
  # 같은 목적지에 두 번 놓지 않도록 place_beside 의 PLACED_DESTS 가 막는다.
  # settings.gradle + build.gradle 은 Gradle 의 표준 배치라 한 디렉터리에 마커가
  # 둘인 것이 정상이고, 그때 .editorconfig 를 두 번 놓으면 두 번째가 충돌로 잡힌다.
  for m in settings.gradle settings.gradle.kts build.gradle build.gradle.kts; do
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
    # settings.json 만 프로젝트 소유다 — 그 안에 프로젝트의 permissions 와 훅 등록이
    # 산다. 스킬·에이전트·훅 스크립트는 킷 소유라 덮는다.
    if [ "$rel" = "settings.json" ]; then place "$f" ".claude/$rel"
    else                                  replace "$f" ".claude/$rel"; fi
  done < <(find "$cc" -type f)

  # settings.json 은 프로젝트 소유라 이미 있으면 덮지 않는다. 그런데 이 파일에는
  # **훅 등록과 permissions 가 들어 있다** — 보존되면 킷이 새로 넣은 규칙이 이 레포에
  # 없는 채로 남고, `ls .claude/` 로는 그 상태를 구분할 수 없다. 그래서 짚어서 말한다.
  # 20라운드 사고의 원인이 정확히 이것이었다: 절은 다 있는데 그 안에 게시 전에 멈추게
  # 하는 규칙이 없었다.
  #
  # **절 이름이 아니라 그 안의 항목을 대조한다.** 이름만 보면 `hooks.PreToolUse` 와
  # `permissions.ask` 를 가진 레포는 언제나 "같다" 로 판정되는데, 실제 사고가 정확히
  # 그 모양이었다 — 두 절이 다 있는 채로 그 **안에** 게시 전에 멈추게 하는 규칙이 없었다.
  #
  # 판정은 dry-run 이든 아니든 같아야 하므로(위 place() 의 불변식) `.ai-kit-new` 파일
  # 존재로 가르지 않는다. 그 파일은 dry-run 에서 안 생긴다. 대신 이 파일이 **충돌로
  # 분류됐는지**를 본다 — 있고 다르다는 뜻이고, 그것이 이 경고의 조건 그대로다.
  _settings_conflict=0
  if [ ${#CONFLICTS[@]} -gt 0 ]; then
    case " ${CONFLICTS[*]} " in *" .claude/settings.json "*) _settings_conflict=1 ;; esac
  fi
  if [ "$_settings_conflict" = 1 ]; then
    _missing=""
    if command -v python3 >/dev/null 2>&1; then
      _missing=$(python3 - "$KIT_ROOT/claude-code/settings.json" "$TARGET/.claude/settings.json" <<'PYEOF'
import json, sys

# 판정 불가를 침묵으로 두지 않는다. 못 읽었으면 못 읽었다고 말한다 — 아래 python3
# 부재 가지와 같은 이유다. 조용히 지나가면 그 검사가 죽은 것을 아무도 모른다.
def fail(why):
    print("!" + why)
    sys.exit(0)

try:
    new = json.load(open(sys.argv[1]))
except Exception as e:
    fail("킷의 settings.json 을 읽지 못해 대조하지 못했습니다 (%s)." % type(e).__name__)
try:
    cur = json.load(open(sys.argv[2]))
except Exception as e:
    fail("이 레포의 .claude/settings.json 을 JSON 으로 읽지 못해 대조하지 못했습니다 "
         "(%s). 주석(//)이나 트레일링 콤마가 있으면 그렇습니다." % type(e).__name__)

def commands(d):
    """등록을 (이벤트, matcher, 명령) 으로 걷는다.

    matcher 를 빼면 안 된다 — 그것도 등록의 일부다. 킷과 같은 명령을 등록하되
    matcher 만 "Edit|Write" 에서 "Write" 로 좁힌 레포는, 명령만 비교하면 "같다" 로
    나온다. 그 레포의 자동 포맷은 Edit 에서 영영 실행되지 않는데 설치기는 이상 없다고 말한다.
    """
    got = set()
    for ev, groups in (d.get("hooks") or {}).items():
        for g in groups or []:
            for h in (g.get("hooks") or []):
                if h.get("command"):
                    got.add((ev, g.get("matcher") or "", h["command"]))
    return got

out = []
try:
  kit_hooks, cur_hooks = commands(new), commands(cur)
  # 명령이 아예 없는 것과 matcher 만 다른 것은 사람이 할 일이 다르다. 갈라서 말한다.
  cur_cmds = {(ev, c) for ev, _m, c in cur_hooks}
  # 스크립트 이름으로도 한 번 본다. 같은 스크립트를 **다른 경로 표기로** 부르는 레포에
  # "부르지 않습니다" 라고 말하면 그건 거짓이다(예: $CLAUDE_PROJECT_DIR 대신 절대경로).
  def base(c):
    return c.rsplit("/", 1)[-1].rstrip('"')
  cur_names = {(ev, base(c)) for ev, _m, c in cur_hooks}
  for ev, m, c in sorted(kit_hooks - cur_hooks):
    name = base(c)
    if (ev, c) in cur_cmds:
        out.append("hooks.%s 가 %s 를 부르지만 matcher 가 다릅니다 (킷: %s)"
                   % (ev, name, m or "(없음)"))
    elif (ev, name) in cur_names:
        out.append("hooks.%s 가 %s 를 부르긴 하지만 명령 문자열이 킷과 다릅니다" % (ev, name))
    else:
        out.append("hooks.%s 가 %s 를 부르지 않습니다" % (ev, name))

  # deny·ask 만 본다. allow 가 빠진 것은 프롬프트가 늘 뿐 막는 규칙이 죽지 않는다.
  np, cp = new.get("permissions") or {}, cur.get("permissions") or {}
  cur_allow = set(cp.get("allow") or [])
  for sec in ("deny", "ask"):
    have = set(cp.get(sec) or [])
    for rule in np.get(sec) or []:
        if rule in have:
            continue
        if rule in cur_allow:
            out.append("permissions.%s 에 %s 가 없습니다 — 이 레포는 그것을 allow 에 두고 있습니다" % (sec, rule))
        else:
            out.append("permissions.%s 에 %s 가 없습니다" % (sec, rule))
except Exception as e:
  fail("이 레포의 .claude/settings.json 구조가 예상과 달라 대조하지 못했습니다 (%s)."
       % type(e).__name__)

print("\n".join(out))
PYEOF
)
    else
      WARNINGS+=(".claude/settings.json 을 보존했는데 python3 이 없어 대조하지 못했습니다.")
      WARNINGS+=("  킷의 claude-code/settings.json 과 직접 비교하세요.")
    fi
    case "$_missing" in
      '!'*)
        WARNINGS+=(".claude/settings.json 을 보존했는데 ${_missing#\!}")
        WARNINGS+=("  킷의 claude-code/settings.json 과 직접 비교하세요.")
        _missing="" ;;
    esac
    if [ -n "$_missing" ]; then
      WARNINGS+=(".claude/settings.json 을 보존했습니다. 킷 파일에는 있고 이 레포 파일에는 없는 것:")
      while IFS= read -r _m; do
        [ -n "$_m" ] && WARNINGS+=("    $_m")
      done <<< "$_missing"
      WARNINGS+=("  훅은 등록이 없으면 .claude/hooks/ 에 파일만 놓인 채 실행되지 않고, permissions 는 그 절이 없으면 그냥 없는 것입니다.")
      if [ "$DRY_RUN" = 1 ]; then
        WARNINGS+=("  실제로 설치하면 .claude/settings.json.ai-kit-new 가 옆에 놓입니다. 그것과 비교하세요.")
      else
        WARNINGS+=("  .claude/settings.json.ai-kit-new 와 비교해 가져오세요.")
      fi
    fi
  fi

fi

# ── 원격 변경: 브랜치 보호 ──
if [ "$DO_PROTECT" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "install: --dry-run 이므로 브랜치 보호는 건드리지 않습니다 (원격 변경입니다)"
  else
    # **사람에게 묻는다.** 이것은 원격 설정을 바꾸는 유일한 자리인데 `permissions.ask`
    # 가 못 잡는다 — 규칙은 에이전트가 입력한 명령 **문자열**만 보므로 `bash install.sh
    # --protect` 안의 `gh api -X PUT` 은 안 보인다. 킷이 `Bash(gh api*)` 를 ask 에
    # 넣어놓고 그것을 비켜가는 실행 파일을 같이 배포하면 그 규칙이 거짓이 된다.
    # 그래서 스크립트가 직접 묻는다. 대답할 사람이 없으면(파이프·CI) 하지 않는다.
    if [ ! -t 0 ]; then
      # **성공으로 끝내지 않는다.** 에이전트의 Bash 호출은 언제나 이 경로이고, exit 0 을
      # 받으면 "보호를 설정했다" 로 보고하게 된다. 부재는 통과가 아니다.
      echo "install: --protect 는 원격 설정을 바꿉니다. 지금은 입력을 받을 수 없어 하지 않았습니다." >&2
      echo "          대화형 터미널에서 다시 실행하세요." >&2
      PROTECT_SKIPPED=1
    else
      printf 'install: %s 의 브랜치 보호를 GitHub 에 설정합니다 — 원격이 바뀝니다. 계속할까요? [y/N] ' "$TARGET"
      read -r _ans
      case "$_ans" in
        [yY]|[yY][eE][sS])
          # 대상 레포 안에서 실행한다. protect-branch.sh 는 gh repo view 로 레포를 찾는데
          # 그것은 CWD 를 본다 — 여기서 cd 하지 않으면 install.sh 를 실행한 자리의
          # 레포에 보호가 걸린다. 대상을 인자로 받는 명령에서 그건 사고다.
          ( cd "$TARGET" && bash "$KIT_ROOT/common/ci/protect-branch.sh" ) \
            || echo "install: 브랜치 보호 설정 실패" >&2 ;;
        *) echo "install: 브랜치 보호를 건드리지 않았습니다." ;;
      esac
    fi
  fi
fi

# ── dry-run 보고: 무엇이 달라지는지 ──
#
# 건수만 세면 "충돌 3건" 까지만 알고 무엇이 왜 다른지는 모른다. 그래서 킷이 놓을
# 트리(STAGE)를 대상과 대조해 파일별로 분류하고 diff 를 붙인다. 병합은 하지 않는다 —
# 트리를 남겨두고 사람이나 에이전트가 보고 정한다.
DIFF_MAX_LINES=${AI_KIT_DIFF_MAX_LINES:-60}   # 파일당
DIFF_MAX_TOTAL=${AI_KIT_DIFF_MAX_TOTAL:-400}  # 전체

# 사라지는 이유는 둘이고, 한 줄로 뭉뚱그리면 하나가 거짓이 된다. --lang 으로 뺀 언어의
# 어댑터는 **킷이 배포하는 파일**이라 "킷이 다시 놓지 않는 것" 이 아니다 — 그렇게 적으면
# 읽는 사람은 킷이 그 언어 지원을 뺐다고 읽는다(실제로 확인함: `--lang py` 재설치에서 셋이 그렇게 나갔다).
why_gone() { # $1=경로 → 사라지는 이유를 덧붙여 출력한다
  local _p="$1" _l
  for _l in $(echo "$DROP" | tr ',' ' '); do
    [ -n "$_l" ] && [ "$_p" = ".ai-kit/gate/adapters/$_l.sh" ] \
      && { printf '%s  (--lang 에서 뺀 언어)\n' "$_p"; return; }
  done
  printf '%s\n' "$_p"
}

dryrun_report() {
  local n_new=0 n_repl=0 n_side=0 n_same=0 n_gone=0
  local list_new="" list_repl="" list_side="" list_gone="" rel f
  while IFS= read -r f; do
    rel=${f#"$STAGE"/}
    if [ ! -e "$TARGET/$rel" ]; then
      n_new=$((n_new + 1)); list_new="${list_new}  + ${rel}"$'\n'
    elif cmp -s "$f" "$TARGET/$rel"; then
      n_same=$((n_same + 1))
    # 내용이 다를 때 설치가 무엇을 하는지는 자리에 따라 다르다. 킷 소유는 교체되고,
    # 프로젝트 소유는 place() 가 원본을 남기고 .ai-kit-new 를 옆에 쓴다.
    # 둘을 한 목록에 담으면 "킷이 놓을 것" 이 절반은 거짓이 된다.
    #
    # **여기의 소유 판정은 위 설치 경로와 같아야 한다.** 갈리면 dry-run 이 예고한 것과
    # 실제 설치가 어긋나고, 그러면 예고를 읽을 이유가 없어진다. 킷 소유는 .ai-kit 전체와
    # .claude 의 스킬·에이전트·훅이고, .claude/settings.json 만 프로젝트 소유다.
    elif case "$rel" in
           .ai-kit/*) true ;;
           .claude/settings.json) false ;;
           .claude/*) true ;;
           docs/process/*) true ;;
           *) false ;;
         esac; then
      n_repl=$((n_repl + 1)); list_repl="${list_repl}  ~ ${rel}"$'\n'
    else
      n_side=$((n_side + 1)); list_side="${list_side}  ~ ${rel}"$'\n'
    fi
  done < <(find "$STAGE" -type f | LC_ALL=C sort)

  # "사라질 것" 은 **다시 세지 않는다.** 설치 경로가 이미 DELETED 에 담아뒀고, 그것이
  # 실제 실행의 `삭제` 칸과 같은 배열이다. 여기서 또 세면 두 벌이 되고, 두 벌은 갈렸다 —
  # 한 번은 예고 3 / 실제 0, 한 번은 예고 1 / 실제 3(그중 둘은 지우지도 않았다).
  #
  # .ai-kit 에서만 나는 일인 것도 그 배열이 이미 반영한다. 킷 소유는 그 밖에도 있지만
  # (.claude 의 스킬·에이전트·훅, docs/process) 그 자리들은 **통째로 비우고 놓는 자리가
  # 아니라 파일 단위로 덮는 자리**라 애초에 사라지는 것이 없다.
  n_gone=${#DELETED[@]}
  for rel in ${DELETED+"${DELETED[@]}"}; do list_gone="${list_gone}  - $(why_gone "$rel")"$'\n'; done

  echo "── dry-run: 아무것도 바꾸지 않았습니다 ──"
  echo ""
  echo "지금 설치하면 — 설치 ${n_new} · 교체 ${n_repl} · 보존 ${n_side} · 동일 ${n_same} · 삭제 ${n_gone}"
  [ -n "$list_repl" ] && { echo ""; echo "교체 — .ai-kit 과 .claude 의 스킬·에이전트·훅은 킷 소유다"; printf '%s' "$list_repl"; }
  [ -n "$list_side" ] && { echo ""; echo "보존 — 이 레포 것을 두고 킷의 것은 <파일>.ai-kit-new 로 옆에 놓는다"; printf '%s' "$list_side"; }
  [ -n "$list_new" ]  && { echo ""; echo "설치"; printf '%s' "$list_new"; }
  [ -n "$list_gone" ] && { echo ""; echo "삭제 — 재설치가 지운다"; printf '%s' "$list_gone"; }

  # diff 는 "이 레포 → 킷" 방향이다. - 가 지금 있는 것, + 가 킷이 놓을 것.
  local list_all="${list_repl}${list_side}"
  if [ -n "$list_all" ]; then
    local shown=0 body cut
    echo ""
    echo "diff (- 지금 이 레포 / + 킷의 것)"
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
    done <<< "$list_all"
  fi

  echo ""
  echo "병합용 트리: $STAGE"
  echo "  킷이 놓을 파일이 들어 있습니다(예고 건수를 맞추려고 .ai-kit/identity 도 넣지만"
  echo "  그것은 킷이 놓는 것이 아니라 보존하는 것입니다). 파일별로 비교하려면:"
  echo "      diff -u <파일> $STAGE/<파일>"
  echo "  임시 디렉터리이므로 정리 정책에 사라질 수 있습니다. 남길 것은 옮겨두세요."
}

# ── 보고 (산출물 규칙 R1: 개수만, 문제만 자세히) ──
if [ "$DRY_RUN" = 1 ]; then
  dryrun_report
else
echo "설치 ${#INSTALLED[@]} · 교체 ${#REPLACED[@]} · 보존 ${#CONFLICTS[@]} · 동일 ${#SKIPPED[@]} · 삭제 ${#DELETED[@]} · 경고 ${#WARNINGS[@]}"
fi
if [ ${#DELETED[@]} -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
  echo ""
  echo "── 삭제 ──"
  for _d in "${DELETED[@]}"; do printf '  - %s' ""; why_gone "$_d"; done
  echo "  .ai-kit 은 통째로 교체되는 자리입니다. 남길 것은 그 밖에 두세요."
fi

if [ "$DO_HOOKS" = 1 ] && [ "$DRY_RUN" = 0 ]; then
  cat <<'MSG'

── 설치기가 한 일 ──
  ✓ 게이트·훅을 .ai-kit/ 에 넣었습니다
  ✓ 훅을 켰습니다 (core.hooksPath → .ai-kit/git-hooks)

── 이제 할 일 ──
  1. .ai-kit/ 을 커밋하세요. 커밋하지 않으면 CI 도, 이 레포를 clone 한 사람도
     게이트를 갖지 못합니다.
  2. docs/process/kit-guide.md 를 읽으세요. 무엇이 자동으로 실행되고, CLAUDE.md 에서
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
  echo "보존 — 이 레포 것을 뒀고 킷의 것은 .ai-kit-new 로 옆에 놓았습니다. 확인 후 병합하세요:"
  printf '  %s\n' "${CONFLICTS[@]}"
fi
if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""; echo "확인 필요:"
  printf '  %s\n' "${WARNINGS[@]}"
fi

# --protect 를 지시받고도 못 했으면 실패다. 부재는 통과가 아니다.
[ "${PROTECT_SKIPPED:-0}" = 1 ] && exit 3
exit 0
