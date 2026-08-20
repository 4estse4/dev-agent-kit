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
gate_run_empty() {
  local name="$1"; shift
  local out
  out=$("$@" 2>&1)
  if [ -z "$out" ]; then
    GATE_PASSED+=("$name")
  else
    GATE_FAILED+=("$name")
    GATE_FAILOUT+=$'\n'"──── ${name} ────"$'\n'"${out}"$'\n'
  fi
}

gate_skip() { GATE_SKIPPED+=("$1"); }

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
