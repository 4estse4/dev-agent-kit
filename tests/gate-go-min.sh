#!/usr/bin/env bash
# CI 에서 Go 를 까는 잡은 모두 그 앞에서 킷의 Go 최소 버전을 본다.
#
# 이 테스트가 있는 이유: 핀한 Go 도구(goimports · govulncheck)는 tool-versions 의 go_min 보다
# 낮은 go 로는 설치되지 않는다. gates.yml 의 잡은 저마다 setup-go 로 Go 를 까는데, go 1.24 로
# Go 를 깐 security 잡은 govulncheck 설치에서 「requires go >= 1.25.0」으로 죽었다(이슈 #93).
# 검사가 한 잡에만 있으면 security 는 그렇게 다른 말을 하며 죽고, 도구를 깔지 않는 coverage 는
# 킷이 지원하지 않는 Go 로 초록을 낸다(같은 실행에서 coverage 가 go 1.24.13 으로 돌았다).
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 을 읽는다. 보는 것:
#   · actions/setup-go 를 쓰는 잡마다, 그보다 앞선 스텝이 gate_go_min_check 를 부른다
#   · 그 스텝의 run 을 설치한 레포에서 돌리면, go 줄이 가장 높은 go.mod(setup-go 가 그것으로
#     Go 를 깐다)가 go_min 보다 낮거나 go 줄이 없을 때 그 파일을 이름대며 실패하고, 아니면
#     통과한다. 더 낮은 보조 모듈이 섞여 있어도 통과한다. 도구 설치를 가르는 것은 돌고 있는
#     go 하나이고, 낮은 go 줄의 모듈도 그 go 로 빌드된다. 러너의 기본 셸처럼 `bash -e` 로 돈다
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
  none) echo "  ✗ setup-go 를 쓰는 잡이 하나도 안 걸렸다 — gates.yml 이 바뀌었나"; fail=1 ;;
  *)
    while read -r st job; do
      if [ "$st" = ok ]; then echo "  ✓ $job 잡은 setup-go 앞에서 go_min 을 본다"
      else echo "  ✗ $job 잡이 go_min 을 보지 않고 setup-go 로 Go 를 깐다"; fail=1; fi
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
IFS=. read -r ma mi _ <<< "$min"; below="$ma.$((mi - 1))"; lower="$ma.$((mi - 2))"
# 버전으로는 낮고 문자열로는 높은 것(1.25 에 대해 1.3). 문자열로 견주면 이것이 통과한다.
short="$ma.$((mi / 10 + 1))"

gomods() { # 인자=「경로:go 줄」. go 줄이 비면 그 줄 없이 만든다
  local a p v
  rm -rf "$R/backend" "$R/tools"
  for a in "$@"; do
    p="${a%%:*}"; v="${a#*:}"
    mkdir -p "$R/$p"
    { echo "module example.com/m"; [ -z "$v" ] || echo "go $v"; } > "$R/$p/go.mod"
  done
}

check() { # $1=잡  $2=설명  $3=기대(fail|pass)  $4=실패할 때 이름대야 할 파일  나머지=gomods 인자
  local job="$1" what="$2" want="$3" names="$4" out rc; shift 4
  gomods "$@"
  out=$(cd "$R" && bash -e "$T/step.$job" 2>&1); rc=$?
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
  check "$job" "go $below 모듈 하나"          fail backend/go.mod "backend:$below"
  check "$job" "go $below · go $lower"       fail backend/go.mod "backend:$below" "tools/x:$lower"
  check "$job" "go $short"                   fail backend/go.mod "backend:$short"
  check "$job" "go 줄 없음"                  fail backend/go.mod "backend:"
  check "$job" "go $min"                     pass ""             "backend:$min"
  check "$job" "go $below · go $min 섞임"     pass ""             "backend:$below" "tools/x:$min"
  check "$job" "go 줄 없음 · go $min"         pass ""             "backend:" "tools/x:$min"
  check "$job" "go $min.3 · go $ma.$((mi + 1))"  pass ""         "backend:$min.3" "tools/x:$ma.$((mi + 1))"
done

rm -rf "$T"
exit $fail
