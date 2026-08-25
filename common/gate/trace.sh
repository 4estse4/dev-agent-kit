#!/usr/bin/env bash
# SPEC 요구 ↔ 추적 매트릭스 정합 검사.
# 요구가 조용히 증발하는 것을 막는 유일한 기계적 장치다.
#
#   trace.sh [--spec docs/SPEC.md] [--matrix docs/traceability.md]
set -uo pipefail

SPEC="docs/SPEC.md"; MATRIX="docs/traceability.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="$2"; shift 2 ;;
    --matrix) MATRIX="$2"; shift 2 ;;
    *) echo "trace: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "trace: git 레포가 아님" >&2; exit 1; }
cd "$REPO" || exit 1
[ -f "$SPEC" ]   || { echo "trace — SPEC 없음($SPEC), 건너뜀"; exit 0; }
[ -f "$MATRIX" ] || { echo "trace ✗ 추적표 없음: $MATRIX" >&2; exit 1; }

ID_RE='R-[A-Z][A-Z0-9]*-[0-9]+'

# SPEC 에서 ID 를 긁을 때 **HTML 주석 안은 제외한다.**
# 예전에는 파일 전체를 긁어서, ID 형식을 설명하는 산문의 예시까지 요구로 읽혔다 —
# 킷을 갓 설치한 레포가 CI 에서 바로 실패했다.
#
# 여러 줄 주석을 처리해야 한다. sed 로 한 줄씩 거르는 방식은 `<!--` 로 시작하는 줄만
# 지워서 둘째 줄부터 살아남고, 정작 이 킷의 SPEC 템플릿이 여러 줄 주석을 쓴다.
_strip_comments() { # stdin -> stdout. 닫히지 않은 주석이 있으면 exit 3.
  awk '
    { line = $0; out = ""
      while (1) {
        if (inc) {
          e = index(line, "-->")
          if (e == 0) { line = ""; break }
          line = substr(line, e + 3); inc = 0
        } else {
          b = index(line, "<!--")
          if (b == 0) { out = out line; break }
          out = out substr(line, 1, b - 1); line = substr(line, b + 4); inc = 1
        }
      }
      print out }
    END { if (inc) exit 3 }
  '
}

# 닫히지 않은 `<!--` 하나가 그 뒤 파일 전체를 삼켜 요구를 통째로 감출 수 있다.
# 오타 하나로 강제가 조용히 꺼지는 것이라, 삼키게 두지 않고 실패시킨다.
_strip_or_die() { # $1=파일
  local out; out=$(_strip_comments < "$1"); local rc=$?
  if [ "$rc" = 3 ]; then
    echo "trace ✗ $1 에 닫히지 않은 <!-- 주석이 있습니다 — 그 뒤 내용이 검사에서 빠집니다." >&2
    exit 1
  fi
  printf '%s\n' "$out"
}

spec_ids=$(_strip_or_die "$SPEC" | grep -oE "$ID_RE" | grep -v 'R-XXX-' | sort -u)
# 추적표도 주석을 걷는다. 안 걷으면 행을 <!-- --> 로 감싸는 것만으로 "추적되고 있다" 가
# 되어, 요구가 조용히 증발하는 것을 막는 유일한 기계적 장치가 꺼진다.
_mx_body=$(_strip_or_die "$MATRIX")
mx_ids=$(printf '%s\n' "$_mx_body" | grep -oE "^\| *$ID_RE" | grep -oE "$ID_RE" | grep -v 'R-XXX-' | sort -u)

fail=0; report=""

missing=$(comm -23 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$mx_ids") | grep -v '^$' || true)
orphan=$(comm -13 <(printf '%s\n' "$spec_ids") <(printf '%s\n' "$mx_ids") | grep -v '^$' || true)

[ -n "$missing" ] && { fail=1; report+=$'\n'"추적표에 없는 SPEC 요구 (요구가 증발할 자리):"$'\n'"$(printf '%s\n' "$missing" | sed 's/^/  /')"$'\n'; }
[ -n "$orphan" ]  && { fail=1; report+=$'\n'"SPEC 에 없는 추적표 행 (유령 요구):"$'\n'"$(printf '%s\n' "$orphan" | sed 's/^/  /')"$'\n'; }

# 상태 칸 검사 + 구현 경로 실재 확인
declare -i n_done=0 n_part=0 n_todo=0 n_out=0
bad_status=""; bad_path=""
while IFS= read -r line; do
  printf '%s' "$line" | grep -qE "^\| *$ID_RE" || continue
  id=$(printf '%s' "$line" | grep -oE "$ID_RE" | head -1)
  [ "${id:0:6}" = "R-XXX-" ] && continue
  impl=$(printf '%s' "$line" | awk -F'|' '{print $4}' | sed 's/^ *//;s/ *$//;s/`//g')
  tests=$(printf '%s' "$line" | awk -F'|' '{print $5}' | sed 's/^ *//;s/ *$//;s/`//g')
  status=$(printf '%s' "$line" | awk -F'|' '{print $6}' | sed 's/^ *//;s/ *$//')
  case "$status" in
    구현됨) n_done+=1 ;;
    부분)   n_part+=1 ;;
    미구현) n_todo+=1 ;;
    범위밖) n_out+=1 ;;
    *) bad_status+="  $id → '${status}'"$'\n'; fail=1; continue ;;
  esac
  if [ "$status" = "구현됨" ] || [ "$status" = "부분" ]; then
    # 구현 칸과 테스트 칸 모두 실재를 확인한다. 테스트 칸을 검사하지 않으면
    # 같은 PR 이 삭제한 파일을 근거로 걸어두고도 게이트가 통과한다.
    for p in $impl $tests; do
      p=${p%%:*}                      # path:symbol 형태 허용
      case "$p" in ""|"—"|"-") continue ;; esac
      [ -e "$p" ] || { bad_path+="  $id → 없는 경로 '$p'"$'\n'; fail=1; }
    done
  fi
done <<< "$_mx_body"

[ -n "$bad_status" ] && report+=$'\n'"상태 칸이 비었거나 값이 잘못됨 (구현됨·부분·미구현·범위밖 중 하나):"$'\n'"$bad_status"
[ -n "$bad_path" ]   && report+=$'\n'"구현됨/부분 인데 구현·테스트 경로가 실재하지 않음:"$'\n'"$bad_path"

total=$(( n_done + n_part + n_todo + n_out ))
summary="trace — 요구 ${total}건: 구현됨 ${n_done} · 부분 ${n_part} · 미구현 ${n_todo} · 범위밖 ${n_out}"

if [ $fail -eq 0 ]; then
  echo "$summary"
  [ $n_todo -gt 0 ] && echo "trace — 미구현 ${n_todo}건이 추적표에 기록돼 있습니다(정상: 숨기지 않았음)."
  exit 0
fi
echo "$summary" >&2
printf '%s\n' "$report" >&2
echo "trace ✗ SPEC 과 추적표가 어긋납니다." >&2
exit 1
