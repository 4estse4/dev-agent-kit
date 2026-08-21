#!/usr/bin/env bash
# 게이트 공용 함수. gate.sh가 source하고 어댑터가 사용한다.
# 출력 규칙(산출물 규칙 R1·R2): 통과는 이름만, 실패만 전체 출력.

GATE_PASSED=()
GATE_FAILED=()
GATE_SKIPPED=()
GATE_FAILOUT=""

gate_have() { command -v "$1" >/dev/null 2>&1; }

# gate_run <표시이름> <명령...>
gate_run() {
  local name="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    GATE_PASSED+=("$name")
  else
    GATE_FAILED+=("$name")
    GATE_FAILOUT+=$'\n'"──── ${name} ────"$'\n'"${out}"$'\n'
  fi
}

# gate_run_empty <표시이름> <명령...>
# 출력이 비어야 통과인 검사용 (gofmt -l, goimports -l 등).
#
# 종료코드도 함께 본다. 출력만 보면 "명령이 실패했는데 아무것도 못 찍은" 경우가
# 통과로 집계된다 — 검사가 고장 났을 때 조용히 green 을 보고하는 것은 검증
# 시스템에서 가장 위험한 결함이다.
gate_run_empty() {
  local name="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -z "$out" ]; then
    GATE_PASSED+=("$name")
    return 0
  fi
  GATE_FAILED+=("$name")
  local detail="$out"
  [ -z "$detail" ] && detail="(출력 없이 종료코드 ${rc} 로 실패 — 도구가 깨졌을 수 있습니다)"
  GATE_FAILOUT+=$'\n'"──── ${name} ────"$'\n'"${detail}"$'\n'
  return 0
}

# 도구가 없어 검사를 건너뛴 것을 기록한다.
# GATE_STRICT=1 이면 건너뜀을 실패로 본다 — CI 에서 도구 부재는 "통과"가 아니라
# "검사가 돌지 않았음"이고, 그것을 green 으로 보고하면 게이트가 거짓말을 한다.
gate_skip() {
  if [ "${GATE_STRICT:-0}" = "1" ]; then
    GATE_FAILED+=("$1(건너뜀)")
    GATE_FAILOUT+=$'\n'"──── $1 ────"$'\n'"도구가 없어 검사가 실행되지 않았습니다. GATE_STRICT=1 에서는 실패로 처리합니다."$'\n'
  else
    GATE_SKIPPED+=("$1")
  fi
}

# gate_report → 실패가 있으면 1
gate_report() {
  local joined
  # 빈 배열 전개는 set -u에서 터지므로 길이를 먼저 확인한다.
  if [ ${#GATE_PASSED[@]} -gt 0 ]; then
    joined=$(printf '%s · ' "${GATE_PASSED[@]}"); echo "gate ✓ ${joined% · }"
  fi
  if [ ${#GATE_SKIPPED[@]} -gt 0 ]; then
    joined=$(printf '%s · ' "${GATE_SKIPPED[@]}"); echo "gate — 건너뜀(도구 없음): ${joined% · }"
  fi
  if [ ${#GATE_FAILED[@]} -gt 0 ]; then
    printf '%s' "$GATE_FAILOUT" >&2
    joined=$(printf '%s · ' "${GATE_FAILED[@]}")
    echo "" >&2
    echo "gate ✗ 실패: ${joined% · }" >&2
    return 1
  fi
  return 0
}
