#!/usr/bin/env bash
# CI 에서 Go 를 설치하는 잡은 모두 그 앞에서 킷의 Go 최소 버전을 본다.
#
# 이 테스트가 있는 이유: 핀한 Go 도구(goimports · golangci-lint · govulncheck)는 tool-versions 의 go_min 보다
# 낮은 go 로는 설치되지 않는다. gates.yml 의 잡은 저마다 setup-go 로 Go 를 설치하는데, go 1.24 로
# Go 를 설치한 security 잡은 govulncheck 설치에서 「requires go >= 1.25.0」으로 죽었다(이슈 #93).
# 검사가 한 잡에만 있으면 security 는 그렇게 다른 말을 하며 죽고, 도구를 설치하지 않는 coverage 는
# 킷이 지원하지 않는 Go 로 초록을 낸다(같은 실행에서 coverage 가 go 1.24.13 으로 실행됐다).
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 을 읽는다. 보는 것:
#   · actions/setup-go 를 쓰는 잡마다, 그보다 앞선 스텝이 gate_go_min_check 를 부른다
#   · 그 스텝의 run 을 설치한 레포에서 실행하면, setup-go 가 Go 를 설치할 go.mod(설치할 Go 가 가장 높은
#     것)의 그 버전이 go_min 보다 낮거나 없을 때 그 파일을 이름대며 실패하고, 아니면 통과한다.
#     설치할 Go 는 toolchain 줄이 있으면 그 버전, 없으면 go 줄이다 — setup-go 가 그렇게 설치한다. 파일을
#     고를 때도 같은 버전으로 순위를 매긴다. 더 낮은 보조 모듈이 섞여 있어도 통과한다. 도구 설치를 가르는 것은 실행 중인
#     go 하나이고, 낮은 go 줄의 모듈도 그 go 로 빌드된다. 러너의 기본 셸처럼 `bash -e` 로 실행된다
#   · 그 버전이 go 1.26 처럼 패치가 없으면 go_min 과 계열끼리, 패치가 있으면(toolchain 줄 포함) 그
#     버전 그대로 견준다 — setup-go 가 앞의 것은 그 계열의 패치 하나를, 뒤의 것은 그 버전을 설치한다.
#     go_min 에 0 이 아닌 패치가 있는 경우도 본다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
Y="$R/.github/workflows/gates.yml"
[ -f "$Y" ] || { echo "  ✗ $Y 가 없다 — 설치 경로가 바뀌었나"; exit 1; }

# 잡마다 setup-go 앞에 검사가 있는지. 주석 줄은 보지 않는다.
report=$(awk '
  /^jobs:$/ { injobs = 1; next }
  !injobs || /^[[:space:]]*#/ { next }
  /^  [a-z_-]+:$/ { job = $1; sub(/:$/, "", job); checked = 0; next }
  /gate_go_min_check/ { checked = 1 }
  /uses: actions\/setup-go@/ { n++; print (checked ? "ok " : "missing ") job }
  END { if (!n) print "none" }
' "$Y")
case "$report" in
  none) echo "  ✗ setup-go 를 쓰는 잡을 하나도 찾지 못했다 — gates.yml 이 바뀌었나"; fail=1 ;;
  *)
    while read -r st job; do
      if [ "$st" = ok ]; then echo "  ✓ $job 잡은 setup-go 앞에서 go_min 을 본다"
      else echo "  ✗ $job 잡이 go_min 을 보지 않고 setup-go 로 Go 를 설치한다"; fail=1; fi
    done <<< "$report"
    ;;
esac

# gate_go_min_check 를 부르는 스텝의 run 을 잡마다 파일로 뽑는다.
awk -v out="$T/step." '
  function flush() { if (body != "" && hit) { f = out job; printf "%s", body > f; close(f) } body = ""; hit = 0; inrun = 0 }
  /^jobs:$/ { injobs = 1; next }
  !injobs { next }
  /^  [a-z_-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
  /^      - / { flush() }
  inrun && /^          / { l = $0; sub(/^          /, "", l); body = body l "\n"; if (l !~ /^[[:space:]]*#/ && l ~ /gate_go_min_check/) hit = 1; next }
  inrun { inrun = 0 }
  /^ +(- )?run: *\|$/ { inrun = 1; next }
  /^ +(- )?run: / { l = $0; sub(/^ +(- )?run: */, "", l); body = l "\n"; if (l ~ /gate_go_min_check/) hit = 1 }
  END { flush() }
' "$Y"

min=$(sed -n 's/^go_min=//p' "$R/.ai-kit/gate/tool-versions")
[ -n "$min" ] || { echo "  ✗ 설치된 tool-versions 에 go_min 이 없다"; exit 1; }
IFS=. read -r ma mi _ <<< "$min"; below="$ma.$((mi - 1))"; lower="$ma.$((mi - 2))"; series="$ma.$mi"
# 버전으로는 낮고 문자열로는 높은 것(go_min 이 1.2x 면 1.3). 문자열로 견주면 이것이 통과한다.
short="$ma.$((mi / 10 + 1))"

gomods() { # 인자=「경로:go 줄[:toolchain 줄]」. go 줄이 비면 그 줄 없이 만든다. 경로가 . 이면 루트
  local a p v tc
  rm -rf "$R/go.mod" "$R/backend" "$R/tools"
  for a in "$@"; do
    p="${a%%:*}"; v="${a#*:}"; tc=""
    case "$v" in *:*) tc="${v#*:}"; v="${v%%:*}" ;; esac
    mkdir -p "$R/$p"
    { echo "module example.com/m"; [ -z "$v" ] || echo "go $v"; [ -z "$tc" ] || echo "toolchain $tc"; } > "$R/$p/go.mod"
  done
}

check() { # $1=잡  $2=설명  $3=기대(fail|pass)  $4=실패할 때 이름대야 할 파일  나머지=gomods 인자
  local job="$1" what="$2" want="$3" names="$4" out rc; shift 4
  gomods "$@"
  # TV 가 비면 CI 스텝처럼 lib.sh 가 제 자리에서 tool-versions 를 찾게 둔다. 설치본 케이스가 그
  # 기본 경로를 지난다 — 모든 케이스에 전달하면 그 경로가 깨져도 초록이었다(PR #108 3라운드 콜드 리뷰).
  if [ -n "$TV" ]; then out=$(cd "$R" && GATE_TOOL_VERSIONS="$TV" bash -e "$T/step.$job" 2>&1); rc=$?
  else out=$(cd "$R" && bash -e "$T/step.$job" 2>&1); rc=$?; fi
  if [ "$want" = fail ]; then
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF "::error file=$names::"; then
      echo "  ✓ $job · $what → 실패하고 $names 를 이름댄다"
    else
      echo "  ✗ $job · $what → rc=$rc, $names 를 이름대며 실패해야 한다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'; fail=1
    fi
  else
    if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '::error'; then
      echo "  ✓ $job · $what → 통과"
    else
      echo "  ✗ $job · $what → rc=$rc, 통과해야 한다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'; fail=1
    fi
  fi
}

steps=$(cd "$T" && ls step.* 2>/dev/null | sed 's/^step\.//')
[ -n "$steps" ] || { echo "  ✗ gate_go_min_check 를 부르는 스텝이 하나도 안 뽑혔다"; fail=1; }
for job in $steps; do
  TV=""
  check "$job" "go $below 모듈 하나"          fail backend/go.mod "backend:$below"
  check "$job" "go $below · go $lower"       fail backend/go.mod "backend:$below" "tools/x:$lower"
  check "$job" "go $short"                   fail backend/go.mod "backend:$short"
  check "$job" "go 줄 없음"                  fail backend/go.mod "backend:"
  check "$job" "go $min"                     pass ""             "backend:$min"
  check "$job" "go $below · go $min 섞임"     pass ""             "backend:$below" "tools/x:$min"
  check "$job" "go 줄 없음 · go $min"         pass ""             "backend:" "tools/x:$min"
  check "$job" "go $series.3 · go $ma.$((mi + 1))"  pass ""      "backend:$series.3" "tools/x:$ma.$((mi + 1))"
  # 패치가 없는 go 줄은 setup-go 가 버전 범위로 받아 그 계열의 패치 하나를 설치한다. 계열끼리 견준다.
  check "$job" "go $series(패치 없음)"         pass ""             "backend:$series"
  # setup-go 는 그 go.mod 에 toolchain 줄이 있으면 그 버전을 설치한다. 검사도 그 줄을 먼저 본다.
  check "$job" "go $below.0 + toolchain go$series.1"   pass ""             "backend:$below.0:go$series.1"
  check "$job" "go $lower + toolchain go$below.9"      fail backend/go.mod "backend:$lower:go$below.9"
  # 파일을 고를 때도 toolchain 줄로 순위를 매긴다. 루트에만 toolchain 줄이 있고 하위 모듈의
  # go 줄이 같거나 높으면, go 줄로만 고를 때 하위 모듈이 뽑혀 멈췄다(이슈 #99).
  check "$job" "루트 go $below.0+toolchain go$series.2 · go $below.0" pass "" ".:$below.0:go$series.2" "tools/x:$below.0"
  check "$job" "루트 go $lower.0+toolchain go$series.1 · go $below.0" pass "" ".:$lower.0:go$series.1" "tools/x:$below.0"

  # go_min 에 0 이 아닌 패치가 있을 때. 지금 핀으로는 안 생기므로 go_min 을 바꾼 tool-versions 로 본다.
  # 패치가 없는 go 줄은 계열끼리, 패치가 있는 go 줄과 toolchain 줄은 그 버전 그대로 견준다.
  TV="$T/tool-versions.p3"
  { grep -v '^go_min=' "$R/.ai-kit/gate/tool-versions"; echo "go_min=$series.3"; } > "$TV"
  check "$job" "go_min $series.3 · go $series(패치 없음)"            pass ""             "backend:$series"
  check "$job" "go_min $series.3 · go $below(패치 없음)"             fail backend/go.mod "backend:$below"
  check "$job" "go_min $series.3 · go $series.2"                    fail backend/go.mod "backend:$series.2"
  check "$job" "go_min $series.3 · go $series.3"                    pass ""             "backend:$series.3"
  check "$job" "go_min $series.3 · toolchain go$series.2"           fail backend/go.mod "backend:$below.0:go$series.2"
  check "$job" "go_min $series.3 · toolchain go$series.4"           pass ""             "backend:$below.0:go$series.4"
done

rm -rf "$T"
exit $fail
