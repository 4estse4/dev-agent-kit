#!/usr/bin/env bash
# 게이트 공용 함수. gate.sh가 source하고 어댑터가 사용한다.
# 출력 규칙(산출물 규칙 R1·R2): 통과는 이름만, 실패만 전체 출력.

GATE_PASSED=()
GATE_FAILED=()
GATE_SKIPPED=()
GATE_FAILOUT=""

gate_have() { command -v "$1" >/dev/null 2>&1; }

# 도구 발견을 사용자의 셸 프로필에 의존하지 않는다.
#
# `go install` 로 받은 도구(goimports·govulncheck 등)는 GOPATH/bin 에 들어가는데
# 그 경로를 PATH 에 넣어두지 않은 환경이 흔하다. 그러면 게이트는 "도구 없음"으로
# 검사를 건너뛰고, 사람마다·머신마다 실제로 도는 검사가 달라진다.
# 게이트가 자기 PATH 를 스스로 넓혀서 그 차이를 없앤다.
gate_extend_path() {
  local d
  for d in \
    "$(command -v go >/dev/null 2>&1 && go env GOPATH 2>/dev/null)/bin" \
    "$(command -v go >/dev/null 2>&1 && go env GOROOT 2>/dev/null)/bin" \
    "$HOME/go/bin" \
    "$HOME/.local/bin" \
    "/usr/local/bin" \
    "/opt/homebrew/bin"
  do
    case "$d" in ""|"/bin") continue ;; esac
    [ -d "$d" ] || continue
    case ":$PATH:" in
      *":$d:"*) ;;
      *) PATH="$d:$PATH" ;;
    esac
  done
  export PATH
}

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
# gate_checksum <.ai-kit 디렉터리> — vendor 내용의 안정적 체크섬.
#
# 이식성 주의 두 가지가 여기 들어 있다:
#  1. shasum(macOS·perl) 과 sha256sum(coreutils) 중 있는 것을 쓴다. 어느 한쪽만
#     가정하면 상대 플랫폼에서 조용히 실패한다.
#  2. xargs 를 쓰지 않는다. 빈 입력에서 GNU xargs 는 명령을 한 번 실행해
#     해시 도구가 stdin 을 기다리며 멈추고, BSD 는 실행하지 않는다 — 갈린다.
# _gate_hash — 있는 해시 도구로 stdin/파일을 해시한다.
# 문자열 변수에 명령을 담아 `$cmd file` 로 부르면 셸의 단어 분리에 의존하게 되고
# zsh 처럼 기본 분리를 하지 않는 셸에서 조용히 깨진다. 함수로 감싸 그 의존을 없앤다.
_gate_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    return 127
  fi
}

# gate_checksum <.ai-kit 디렉터리> — vendor 내용의 안정적 체크섬.
#
# 이식성 주의 두 가지가 여기 들어 있다:
#  1. shasum(macOS·perl) 과 sha256sum(coreutils) 중 있는 것을 쓴다. 어느 한쪽만
#     가정하면 상대 플랫폼에서 조용히 실패한다.
#  2. xargs 를 쓰지 않는다. 빈 입력에서 GNU xargs 는 명령을 한 번 실행해
#     해시 도구가 stdin 을 기다리며 멈추고, BSD 는 실행하지 않는다 — 갈린다.
gate_checksum() {
  local dir="$1"
  _gate_hash </dev/null >/dev/null 2>&1 || return 1   # 해시 도구 없음
  ( cd "$dir" 2>/dev/null || exit 1
    find gate git-hooks -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      _gate_hash "$f"
    done | _gate_hash | cut -c1-16 )
}

gate_skip() {
  if [ "${GATE_STRICT:-0}" = "1" ]; then
    GATE_FAILED+=("$1(건너뜀)")
    GATE_FAILOUT+=$'\n'"──── $1 ────"$'\n'"도구를 찾지 못해 이 검사가 실행되지 않았습니다."$'\n'"게이트는 GOPATH/bin·/usr/local/bin·/opt/homebrew/bin 을 자동으로 찾습니다 —"$'\n'"여기까지 왔다면 도구가 설치되지 않았거나 버전 매니저(nvm·asdf 등) 안에 있습니다."$'\n'"GATE_STRICT=0 으로 건너뛸 수 있으나, 그러면 이 검사는 돌지 않은 채 통과합니다."$'\n'
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
