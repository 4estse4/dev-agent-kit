#!/usr/bin/env bash
# 단일 게이트 정의. agent hook · git hook · CI가 모두 이것을 호출한다.
# 명령을 각자 복붙하면 조용히 드리프트하므로 정의는 여기 한 곳에만 둔다.
#
#   gate.sh              변경 영역만 검사 (기본: main/master merge-base 기준)
#   gate.sh --base <ref> 기준 ref 지정
#   gate.sh --all        전체 검사 (CI)
set -uo pipefail

# 형제 파일은 자기 디렉터리 기준으로 찾는다 — 킷 원본이든 대상 레포에 vendor 된
# .ai-kit/gate/ 든 동일하게 동작한다.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gate: git 레포가 아님" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

BASE=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --all)  ALL=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "gate: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

# --all 은 CI 에서 쓰인다. 거기서 도구 부재는 통과가 아니라 "검사 안 됨"이므로
# 엄격 모드를 기본으로 켠다. 로컬 훅은 도구가 없을 수 있어 관대하게 둔다.
[ "$ALL" = 1 ] && : "${GATE_STRICT:=1}"
export GATE_STRICT="${GATE_STRICT:-0}"

source "$SELF_DIR/lib.sh"

# ── 변경 영역 판정 (판정 불가면 전체 검사로 폴백 — 조용히 통과시키지 않는다) ──
CHANGED=""
if [ "$ALL" = 0 ]; then
  if [ -z "$BASE" ]; then
    for ref in main master; do
      git rev-parse --verify -q "$ref" >/dev/null 2>&1 && { BASE="$ref"; break; }
    done
  fi
  [ -n "$BASE" ] && CHANGED=$(git diff --name-only "$BASE...HEAD" 2>/dev/null || true)
  [ -z "$CHANGED" ] && CHANGED=$(git diff --name-only HEAD 2>/dev/null || true)
  [ -z "$CHANGED" ] && ALL=1
fi

# ── 어댑터 자동 발견: 마커 파일이 있는 디렉터리 = 그 언어의 루트 ──
TARGETS=()
discover() { # $1=마커파일 $2=어댑터명
  local marker dir rel
  while IFS= read -r marker; do
    dir=$(dirname "$marker"); rel=${dir#./}; [ "$rel" = "." ] && rel=""
    if [ "$ALL" = 1 ] || [ -z "$rel" ] || printf '%s\n' "$CHANGED" | grep -q "^${rel}/"; then
      TARGETS+=("$2|$dir")
    fi
  done < <(find . -maxdepth 3 -name "$1" -not -path '*/node_modules/*' -not -path './.git/*' 2>/dev/null)
}
discover go.mod       go
discover package.json ts

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
