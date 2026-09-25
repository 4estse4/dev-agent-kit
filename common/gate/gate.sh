#!/usr/bin/env bash
# 단일 게이트 정의. agent hook · git hook · CI가 모두 이것을 호출한다.
# 명령을 각자 복붙하면 조용히 드리프트하므로 정의는 여기 한 곳에만 둔다.
#
#   gate.sh              변경 영역만 검사 (기본: main/master merge-base 기준)
#   gate.sh --base <ref> 기준 ref 지정
#   gate.sh --all        전체 검사 (CI)
#   gate.sh --lint       린트·정적분석만 (테스트·빌드 제외) — pre-commit 이 쓴다
#   gate.sh --staged     검사 범위를 스테이지된 파일로 (커밋하려는 그것)
set -uo pipefail

# 형제 파일은 자기 디렉터리 기준으로 찾는다 — 킷 원본이든 대상 레포에 vendor 된
# .ai-kit/gate/ 든 동일하게 동작한다.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gate: git 레포가 아님" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

BASE=""; ALL=0
# --lint: 린트·정적분석만 실행한다(테스트·빌드 제외). pre-commit 이 쓴다.
# 게이트 정의를 훅에 복붙하지 않기 위한 모드다 — 검사 목록이 두 벌이 되면 어긋난다.
GATE_LINT_ONLY=0
# --staged: 검사 범위를 "커밋하려는 것" 으로 잡는다.
# 이게 없으면 pre-commit 이 엉뚱한 것을 검사한다 — 기본 범위는 main...HEAD 라서,
# 브랜치에 커밋이 이미 하나라도 있으면 **지금 스테이지한 파일이 범위 밖**이 된다.
# 킷이 강제하는 흐름(보호 브랜치 → feature 브랜치)에서는 두 번째 커밋부터 항상 그렇다.
STAGED=0

while [ $# -gt 0 ]; do
  case "$1" in
    # 값을 받는 플래그는 값이 실제로 있는지 먼저 본다. 안 보면 `shift 2` 가 인자
    # 하나를 못 넘겨 실패하는데, 실패해도 루프는 계속 반복되어 **같은 인자를 영원히
    # 다시 읽는다** — 출력 한 줄 없이 멈춘 것처럼 보인다(실제로 확인함).
    --base)
      [ $# -ge 2 ] || { echo "gate: --base 에 값이 필요합니다 (예: --base origin/main)" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
    --all)  ALL=1; shift ;;
    --lint) GATE_LINT_ONLY=1; shift ;;
    --staged) STAGED=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "gate: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

# 도구가 없으면 "검사되지 않았다" 이지 "통과" 가 아니다. **로컬도 CI 와 같은 기준**이다.
#
# 예전에는 로컬만 관대했는데, 그러면 로컬에서 통과한 것이 CI 에서 실패한다.
# 그 왕복(푸시 → 몇 분 대기 → 실패 확인 → 로컬 수정 → 다시 푸시)은 로컬에서
# 30초면 끝날 일을 공용 자원과 사람 시간으로 치르는 것이다.
#
# 불가피할 때만 AI_KIT_ALLOW_MISSING_TOOLS=1 로 관대 모드로 내린다.
# 조용히 내려가지 않는다 — 무엇이 검사되지 않는지 크게 찍는다.
export GATE_LINT_ONLY
if [ "${AI_KIT_ALLOW_MISSING_TOOLS:-0}" = "1" ]; then
  GATE_STRICT=0
  echo "gate — AI_KIT_ALLOW_MISSING_TOOLS=1: 도구가 없는 검사는 건너뜁니다(통과가 아닙니다)." >&2
else
  : "${GATE_STRICT:=1}"
fi
export GATE_STRICT

source "$SELF_DIR/lib.sh"

# 도구를 찾기 전에 PATH 를 넓힌다 — 어느 환경에서든 같은 검사가 실행되어야 한다.
gate_extend_path

# ── 변경 영역 판정 (판정 불가면 전체 검사로 폴백 — 조용히 통과시키지 않는다) ──
CHANGED=""
if [ "$ALL" = 0 ]; then
  if [ -z "$BASE" ]; then
    for ref in main master; do
      git rev-parse --verify -q "$ref" >/dev/null 2>&1 && { BASE="$ref"; break; }
    done
  fi
  if [ "$STAGED" = 1 ]; then
    # quotePath 기본값(true)은 비ASCII 경로를 octal 로 이스케이프해 따옴표째 내보낸다.
    # 그 이름으로는 파일을 못 찾는다 — 한국어 문서가 산출물인 이 킷에서 바로 물린다.
    # 아래 두 줄도 같은 자리다. 한때 이 줄만 고치고 두 줄은 그대로 뒀다(실제로 확인함: 중첩
    # 모듈의 한글 파일만 바뀌면 "검사 대상 없음" 으로 조용히 통과).
    CHANGED=$(git -c core.quotePath=false diff --cached --name-only 2>/dev/null || true)
  fi
  [ -z "$CHANGED" ] && [ -n "$BASE" ] && CHANGED=$(git -c core.quotePath=false diff --name-only "$BASE...HEAD" 2>/dev/null || true)
  [ -z "$CHANGED" ] && [ "$STAGED" != 1 ] && CHANGED=$(git -c core.quotePath=false diff --name-only HEAD 2>/dev/null || true)
  [ -z "$CHANGED" ] && ALL=1
fi

# ── 어댑터 자동 발견: 마커 파일이 있는 디렉터리 = 그 언어의 루트 ──
TARGETS=()
# 바뀐 경로 중에 모듈 $1 아래의 것이 있나. $1 은 find 가 디스크에서 낸 이름이다.
#
# 문자 그대로 앞부분을 대조한다. `grep "^$rel/"` 로 쓰던 때는 모듈 경로가 정규식이 되어
# `app[1]` 같은 루트가 자기 안의 파일과 안 맞았다. awk 에 -v 로 넘기지 않는 것은 -v 가
# 역슬래시를 풀기 때문이다.
# 목록을 파이프로 넘기지 않는다. pipefail 아래에서 받는 쪽이 첫 매치에서 끝나면 남은 목록을
# 쓰던 쪽이 SIGPIPE 로 죽고 그것이 결과가 된다 — 변경 목록이 파이프 버퍼보다 긴 브랜치에서
# 앞쪽 모듈이 "검사 대상 없음" 으로 빠졌다(실제로 확인함).
# 유니코드 정규화는 맞추지 않는다. macOS 에서 Finder 로 만든 한글 이름의 모듈 폴더는 디스크와
# git 의 바이트가 달라 여기서 안 맞는다. 맞추려다 생긴 비용이 더 커서 안 하기로 했다 —
# docs/process/kit-guide.md 4절.
changed_under() {
  P="$1/" awk 'index($0, ENVIRON["P"]) == 1 { f = 1; exit } END { exit !f }' <<< "$CHANGED"
}
discover() { # $1=마커파일 $2=어댑터명
  local marker dir rel
  # 깊이를 제한하지 않는다. 예전에는 maxdepth 3 이었는데 apps/svc/api/go.mod 같은
  # 구조에서 마커를 못 찾고 "검사 대상 없음" 으로 **조용히 통과**했다.
  # 노이즈는 깊이가 아니라 lib.sh 의 GATE_PRUNE_DIRS 로 막는다.
  # shellcheck disable=SC2046
  while IFS= read -r marker; do
    dir=$(dirname "$marker"); rel=${dir#./}; [ "$rel" = "." ] && rel=""
    if [ "$ALL" = 1 ] || [ -z "$rel" ] || changed_under "$rel"; then
      TARGETS+=("$2|$dir")
    fi
  done < <(find . \( $(gate_prune_expr) \) -prune -o -name "$1" -print 2>/dev/null)
}

discover go.mod       go
discover package.json ts
# JVM: 빌드 루트 마커를 먼저 본다. 멀티모듈이 기본이라 build.gradle 만 찾으면
# 루트와 서브모듈이 모두 잡히는데, 서브모듈에서 빌드를 부르면 래퍼도 settings 도
# 없어 깨진다. 루트에서 한 번 실행하는 것이 모든 모듈을 덮는다.
discover settings.gradle     jvm
discover settings.gradle.kts jvm
discover build.gradle        jvm
discover build.gradle.kts    jvm
discover pyproject.toml      py

# 조상 디렉터리의 실행이 이미 덮는 자손을 뺀다 — **JVM 에만 적용한다.**
#
# Gradle 은 루트에서 한 번 부르면 서브모듈을 다 덮으므로 자손을 또 부르면
# 낭비이고, 서브모듈엔 래퍼도 settings 도 없어 깨진다.
#
# Go·TS·Python 은 다르다. 중첩된 go.mod 는 **독립 모듈**이라 조상에서 `go vet ./...`
# 을 실행해도 자손에 닿지 않는다. 여기에 같은 규칙을 적용했다가 중첩 모듈이 통째로
# 검사에서 빠졌고(콜드 리뷰가 잡음), 그건 깊이 제한을 없앤 이유와 정확히 같은 실패다.
# 같은 디렉터리에 마커가 둘인 경우(build.gradle + settings.gradle)는 어댑터와
# 무관하게 한 번만 남긴다.
if [ ${#TARGETS[@]} -gt 1 ]; then
  _kept=()
  for t in "${TARGETS[@]}"; do
    a=${t%%|*}; d=${t#*|}; drop=0
    for u in "${TARGETS[@]}"; do
      b=${u%%|*}; e=${u#*|}
      [ "$a" = "$b" ] || continue
      [ "$a" = "jvm" ] || continue
      [ "$d" = "$e" ] && continue
      case "$d/" in "$e"/*) drop=1; break ;; esac
    done
    if [ "$drop" = 0 ]; then
      # 같은 디렉터리에 마커가 둘 이상이면(build.gradle + settings.gradle) 한 번만 남긴다.
      case " ${_kept[*]:-} " in *" $a|$d "*) ;; *) _kept+=("$a|$d") ;; esac
    fi
  done
  TARGETS=("${_kept[@]}")
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "gate — 검사 대상 없음"
  exit 0
fi

# ── 실행: 어댑터를 source해서 결과를 한 프로세스에 모은다 ──
for t in "${TARGETS[@]}"; do
  adapter=${t%%|*}; dir=${t#*|}
  script="$SELF_DIR/adapters/${adapter}.sh"
  [ -f "$script" ] || { gate_skip "$adapter(어댑터 없음)"; continue; }
  pushd "$dir" >/dev/null || continue
  # shellcheck source=/dev/null
  source "$script"
  popd >/dev/null || true
done

gate_report
