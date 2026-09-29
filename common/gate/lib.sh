#!/usr/bin/env bash
# 게이트 공용 함수. gate.sh가 source하고 어댑터가 사용한다.
# 출력 규칙(산출물 규칙 R1·R2): 통과는 이름만, 실패만 전체 출력.

GATE_PASSED=()
GATE_FAILED=()
GATE_SKIPPED=()
GATE_ABSENT=()
GATE_FAILOUT=""

gate_have() { command -v "$1" >/dev/null 2>&1; }

# 마커를 찾을 때 건너뛸 디렉터리. **게이트와 설치기가 이 하나를 함께 쓴다** —
# 두 곳에 적으면 모르는 사이에 서로 달라진다(gate.sh 머리말의 원칙).
#
# 목록이 짧은 이유는 실제로 확인한 결과다. "빌드 산출물이니 걸러야지" 싶은 이름들을 넣었다가
# **회귀를 만들었다** — vendor·build·out·dist·target·coverage 는 업무 도메인
# 이름이기도 해서(`services/vendor` 같은), 이름으로 제외하면 멀쩡한 모듈이 검사에서
# 통째로 사라진다. 실제로 그렇게 됐고 콜드 리뷰가 찾아냈다.
#
# 한 Go+React 모노레포에서 센 결과: 마커 파일이 들어 있는 것은
# node_modules 뿐이다.
#   frontend/node_modules            package.json 264개
#   frontend/dist · 빈 node_modules  0개
#   Go 의 vendor/(go mod vendor 산출) go.mod 0개 · .go 23개
# 그래서 이름으로 거르는 대상은 **마커가 실제로 들어 있는 것과 VCS 내부**로 한정한다.
# 나머지는 걸러도 얻는 것이 없고 잃을 것만 있다.
GATE_PRUNE_DIRS="${AI_KIT_PRUNE_DIRS:-.git node_modules .venv .tox __pycache__}"

# find 에 전달할 prune 표현식을 조립한다. 게이트와 설치기가 같은 함수를 쓴다.
gate_prune_expr() { # 출력: -name a -o -name b ...  (호출부가 \( \) 로 감싼다)
  local d first=1
  for d in $GATE_PRUNE_DIRS; do
    [ "$first" = 1 ] || printf ' -o'
    printf ' -name %s' "$d"; first=0
  done
}

# go.mod 하나에서 setup-go 가 받을 Go 버전과 그 줄 이름을 낸다: 「<버전> toolchain」 또는
# 「<버전> go」. 둘 다 없으면 아무것도 안 낸다. 버전에 패치가 없으면 setup-go 는 그 계열의 패치
# 하나를 설치한다(아래 gate_go_min_check).
# setup-go 는 그 파일에 `toolchain go1.*` 줄이 있으면 그 버전을, 없으면 go 줄의 버전을 설치한다(setup-go v7 의
# parseGoVersionFile, 러너에서 봤다). go 줄을 올리는 go 명령이 toolchain 줄에 자기 버전을 같이
# 쓰므로(go.dev/doc/toolchain), go 줄을 낮게 둔 채 새 Go 로 빌드하는 모듈이 흔하다.
# 파일을 고르는 gate_go_highest 와 판정하는 gate_go_min_check 가 이 하나를 쓴다. 한때 판정만
# toolchain 줄을 봐서, 루트에만 그 줄이 있으면 하위 모듈을 골라 멈췄다.
gate_go_setup_version() { # $1=go.mod
  local tc v
  tc=$(awk '$1 == "toolchain" { print $2; exit }' "$1")
  if [ "${tc#go1.}" != "$tc" ]; then echo "${tc#go} toolchain"; return; fi
  v=$(awk '$1 == "go" { print $2; exit }' "$1")
  [ -z "$v" ] || echo "$v go"
}

# go.mod 경로들(표준입력, 한 줄에 하나) 가운데 setup-go 가 설치할 Go(위 gate_go_setup_version)가 가장
# 높은 것을 낸다. CI 의 setup-go 가 이 파일로 Go 를 설치한다. setup-go 는 GOTOOLCHAIN=local 을 설정해
# 더 높은 go 를 받아 오지 않으므로(실제로 확인함), 모듈이 여럿이면 가장 높은 것을 설치해야 모든 모듈이 실행된다.
# 같으면 경로 순으로 뒤의 것이다.
gate_go_highest() {
  local f v
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    v=$(gate_go_setup_version "$f"); v="${v%% *}"
    printf '%s\t%s\n' "${v:-0}" "$f"
  done | sort -V | tail -1 | cut -f2-
}

# CI 가 Go 를 설치하는 go.mod(위 gate_go_highest)에서 setup-go 가 설치할 버전이 tool-versions 의 go_min
# 이상인지 본다. 아니면 그 파일과 이유를 GitHub 주석(::error)으로 내고 실패한다.
# 보는 것은 그 하나다. 핀한 Go 도구를 설치할 수 있는지 정하는 것은 실행 중인 go 이고, go 줄이 더 낮은
# 보조 모듈도 그 go 로 빌드된다. 모든 go.mod 를 보면 전에 동작하던 멀티모듈 레포가 멈춘다.
# 견주는 법은 setup-go 가 그 버전을 받는 법을 따른다. go 1.27 처럼 패치가 없으면 버전 범위로
# 받아 그 계열(1.27.x)에서 러너가 캐시에 가진 가장 높은 것을, 없으면 가장 새것을 설치한다(setup-go v7
# 의 getGo, 러너에서 봤다). 그래서 go_min 과 계열끼리 견준다. 이 통과는 캐시의 패치가 go_min 의
# 패치 이상이라는 전제에 기댄다. 낮으면 이 검사를 통과하고도 도구 설치가 「requires go >= …」로
# 실패한다. go_min 에 0 이 아닌 패치를 적는 날 이 전제를 다시 본다. 패치가 있으면(go 1.27.0 ·
# toolchain go1.27.1) 그 버전을 그대로 설치하므로 그대로 견준다. go_min 은 패치까지 적으므로(1.27.0)
# 그대로만 견주면, Go 의 순서로 1.27 < 1.27.0 이라 1.27.x 를 설치하는 go 1.27 레포가 멈춘다.
# sort -V 는 이 형태들을 Go 의 순서대로 놓는다(1.27 < 1.27.0 < 1.27.1, go.dev/doc/toolchain).
# CI 에서 setup-go 를 쓰는 잡이 모두 그 앞에서 부른다. 잡은 저마다 Go 를 설치해서, 한 잡에만 두면
# security 는 govulncheck 설치에서 「requires go >= …」라는 다른 오류로 실패하고(실제로 확인함), 도구를
# 설치하지 않는 coverage 는 킷이 지원하지 않는 Go 로 초록을 낸다(실제로 확인함).
gate_go_min_check() {
  local min f v line want what raise
  min=$(gate_tool_version go_min)
  [ -n "$min" ] || { echo "::error::.ai-kit/gate/tool-versions 에 go_min 이 없습니다 — 킷을 갱신하세요"; return 1; }
  f=$(find . \( $(gate_prune_expr) \) -prune -o -name go.mod -print | gate_go_highest)
  read -r v line <<< "$(gate_go_setup_version "$f")"
  case "$v" in
    *.*.*) want="$min" ;;
    *)     want=$(printf '%s\n' "$min" | cut -d. -f1-2) ;;
  esac
  [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$want" "$v" | sort -V | head -1)" = "$want" ] && return 0
  case "$line" in
    toolchain) what="toolchain 줄이 go$v 입니다"; raise="toolchain 줄을 go$min 이상으로" ;;
    go)        what="go 줄이 $v 입니다";          raise="go 줄을 $want 이상으로" ;;
    *)         what="go 줄이 없습니다";           raise="go 줄을 $min 이상으로" ;;
  esac
  echo "::error file=${f#./}::${f#./} 의 $what. CI 는 레포의 go.mod 가운데 설치할 Go 가 가장 높은 이 파일로 Go 를 설치합니다(toolchain 줄이 있으면 그 버전, 없으면 go 줄. go 줄이 1.27 처럼 패치가 없으면 그 계열의 패치 하나). 킷은 Go $min 이상만 지원합니다 — 그보다 낮은 go 로는 핀한 Go 도구(goimports · golangci-lint · govulncheck)가 설치되지 않거나, golangci-lint 의 gofumpt 가 기준으로 삼는 Go 의 gofmt 와 포맷이 어긋나 게이트를 통과하지 못하는 코드가 생깁니다(.ai-kit/gate/tool-versions 의 go_min 주석). ${raise} 올리세요."
  return 1
}

# 레포 루트에 .nvmrc 가 있는지 본다. 없으면 GitHub 주석(::error)으로 이유를 말하고 실패한다.
# CI 의 setup-node 가 그 파일로 node 를 설치한다. node 는 잡 하나에 하나라 py 의 .python-version 처럼
# 루트에 둔다. setup-node 를 쓰는 잡이 모두 그 앞에서 부른다. 한때 setup-node 가 루트의 .nvmrc 와
# lockfile 을 가정하고, continue-on-error 때문에 그 실패가 초록으로 끝났다.
gate_nvmrc_check() {
  local found
  [ -f .nvmrc ] && return 0
  found=$(find . \( $(gate_prune_expr) \) -prune -o -name .nvmrc -print | sed 's#^\./##' | paste -sd ' ' -)
  echo "::error::.nvmrc 가 레포 루트에 없습니다${found:+(하위 디렉터리에는 있습니다: $found)}. CI 는 node 를 잡마다 하나만 설치하고 그 버전을 루트의 .nvmrc 에서 읽습니다. 레포 루트에 node 버전 한 줄(예: 22)로 만들고 커밋하세요."
  return 1
}

# Go 도구를 부르는 방법을 한 곳에서 정한다.
#
# go.mod 의 `tool` 지시어(Go 1.24+)가 선언한 도구는 `go tool <이름>` 으로 부를 수 있고,
# 그러면 **로컬과 CI 가 반드시 같은 버전**을 쓴다. PATH 의 바이너리는 사람마다 버전이
# 다르고, 아예 없으면 검사가 알림 없이 빠진다 — 실제로 이 킷을 쓰는 머신에 goimports 가
# 없어서 편집 시 import 정렬이 안 되고 있었고 아무도 몰랐다.
#
# 선언돼 있으면 그것을 쓰고(버전 일치가 우선), 없으면 PATH 를 본다.
# 출력: 실행할 명령을 배열로 echo. 못 찾으면 빈 문자열 + 실패.
gate_go_tool() { # $1=도구 이름 (예: goimports)
  if [ -f go.mod ] && grep -qE "^(tool[[:space:]]|[[:space:]]*).*/$1\$" go.mod 2>/dev/null; then
    printf 'go tool %s' "$1"; return 0
  fi
  if gate_have "$1"; then printf '%s' "$1"; return 0; fi
  return 1
}

# 고정 버전을 읽는다. 버전은 tool-versions 한 곳에만 적는다 — 여기나 CI 에
# 숫자를 적어 두면 반드시 어긋난다.
# 경로는 gate.sh 가 이미 계산한 SELF_DIR 을 쓰고, 없으면 BASH_SOURCE 로 되짚는다.
# (BASH_SOURCE 는 셸에 따라 다르게 정해지므로 여기에만 의존하지 않는다.)
GATE_TOOL_VERSIONS="${GATE_TOOL_VERSIONS:-${SELF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)}/tool-versions}"
gate_tool_version() { # $1=키(goimports·golangci_lint·ruff·ktlint·govulncheck)
  [ -f "$GATE_TOOL_VERSIONS" ] || return 1
  sed -n "s/^$1=//p" "$GATE_TOOL_VERSIONS" | head -1
}

# 도구별 설치 명령. 안내가 없으면 사람은 검색부터 해야 하고, 그러면 사람마다 버전이 달라진다.
#
# **버전 폴백을 두지 않는다.** ${v:-1.8.0} 이나 ${v:-latest} 같은 기본값을 넣으면
# tool-versions 를 못 읽었을 때 알리지 않고 다른 버전을 안내하게 되고, 그 순간 단일 출처가
# 둘이 된다. @latest 폴백은 더 나쁘다 — 재현성 때문에 핀해놓고 정반대를 시키는 꼴이다.
# 못 읽으면 못 읽었다고 말한다.
gate_install_hint() { # $1=도구 이름
  local v
  case "$1" in
    goimports|golangci-lint|govulncheck|ruff|ktlint)
      case "$1" in
        goimports)     v=$(gate_tool_version goimports) ;;
        golangci-lint) v=$(gate_tool_version golangci_lint) ;;
        govulncheck)   v=$(gate_tool_version govulncheck) ;;
        ruff)          v=$(gate_tool_version ruff) ;;
        ktlint)        v=$(gate_tool_version ktlint) ;;
      esac
      if [ -z "$v" ]; then
        echo "고정 버전을 읽지 못했습니다 — $GATE_TOOL_VERSIONS 를 확인하세요"
        return 0
      fi
      case "$1" in
        goimports)     echo "go install golang.org/x/tools/cmd/goimports@$v" ;;
        golangci-lint) echo "go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$v" ;;
        govulncheck)   echo "go install golang.org/x/vuln/cmd/govulncheck@$v" ;;
        ruff)          echo "uv tool install ruff==$v  (또는 pipx install ruff==$v)" ;;
        ktlint)        echo "bash .ai-kit/gate/install-tools.sh  (수동: curl -fsSLo \"\$HOME/.local/bin/ktlint\" https://github.com/ktlint/ktlint/releases/download/$v/ktlint && chmod +x \"\$HOME/.local/bin/ktlint\")" ;;
      esac
      ;;
    mypy|pytest)          echo "프로젝트 의존성으로 설치한다(uv sync / pip install -e '.[dev]')" ;;
    go|java|python3|node) echo "런타임이다 — 프로젝트가 요구하는 버전을 설치한다" ;;
    gradle)               echo "프로젝트에 gradle 래퍼(./gradlew)를 커밋하는 것이 정석이다" ;;
    *)                    echo "" ;;
  esac
}

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
# 종료코드도 함께 본다. 출력만 보면 "명령이 실패했는데 아무것도 출력하지 못한" 경우가
# 통과로 집계된다 — 검사가 고장 났을 때 그것을 알리지 않고 통과로 보고하는 것은 검증
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

# gate_absent: 도구는 있는데 **프로젝트가 그 단계를 선언하지 않은** 경우.
# gate_skip 과 다르다 — 환경이 덜 갖춰진 게 아니라 프로젝트가 그렇게 구성한 것이고,
# 이걸 실패로 만들면 평범한 JS 프로젝트가 쓰지도 않는 typecheck 스크립트를 억지로
# 만들어야 한다. 그러면 사람은 AI_KIT_ALLOW_MISSING_TOOLS 를 상시로 켜게 되고,
# 그 순간 도구가 정말로 없는 경우를 막는 검사까지 함께 꺼진다. 보고는 하되 막지 않는다.
gate_absent() { GATE_ABSENT+=("$1"); }

# 도구가 없어 검사를 건너뛴 것을 기록한다.
# GATE_STRICT=1 이면 건너뜀을 실패로 처리한다 — CI 에서 도구 부재는 "통과"가 아니라
# "검사가 실행되지 않았음"이고, 그것을 통과로 보고하면 게이트가 거짓말을 한다.
gate_skip() {
  # 이름에서 도구를 뽑는다. "golangci-lint" · "ruff" · "gradle(미설치·래퍼없음)" 등.
  local tool="${1%%(*}"; tool="${tool%% *}"
  local hint; hint=$(gate_install_hint "$tool")
  if [ "${GATE_STRICT:-0}" = "1" ]; then
    GATE_FAILED+=("$1(건너뜀)")
    GATE_FAILOUT+=$'\n'"──── $1 ────"$'\n'"이 검사를 실행할 도구가 없어 **검사되지 않았습니다.**"$'\n'
    if [ -n "$hint" ]; then
      GATE_FAILOUT+=$'\n'"  설치:  $hint"$'\n'
    fi
    GATE_FAILOUT+=$'\n'"  전부 설치:  bash .ai-kit/gate/install-tools.sh"$'\n'"  버전은 .ai-kit/gate/tool-versions 가 단일 출처입니다."$'\n'$'\n'"  불가피하게 건너뛰려면(그 검사는 실행되지 않고, 그 때문에 게이트가 실패하지도 않습니다):"$'\n'"    AI_KIT_ALLOW_MISSING_TOOLS=1 <명령>"$'\n'
  else
    GATE_SKIPPED+=("$1")
  fi
}

# gate_report → 실패가 있으면 1
gate_report() {
  local joined
  # 빈 배열 전개는 set -u 아래에서 오류가 나므로 길이를 먼저 확인한다.
  if [ ${#GATE_PASSED[@]} -gt 0 ]; then
    joined=$(printf '%s · ' "${GATE_PASSED[@]}"); echo "gate ✓ ${joined% · }"
  fi
  if [ ${#GATE_ABSENT[@]} -gt 0 ]; then
    joined=$(printf '%s · ' "${GATE_ABSENT[@]}"); echo "gate — 이 프로젝트에 없는 단계: ${joined% · }"
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
