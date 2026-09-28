#!/usr/bin/env bash
# common/ci/check-go-min.sh 가 go_min 과 핀한 Go 도구의 go 줄이 어긋난 것을 찾아내는가.
#
# 이 테스트가 있는 이유: tool-versions 의 go_min 은 gates.yml 이 go install 로 설치하는 도구들이 요구하는
# go(그 모듈의 go 줄)와 그 도구가 쓰는 gofumpt 의 기준 Go 가운데 가장 높은 것과 같아야 한다. 낮으면 도구가
# 설치되지 않거나 gofumpt 와 포맷이 어긋나고, 높으면 gate_go_min_check 가 출력하는 이유가 거짓이 된다.
# 한때 go_min 을 goimports 와 govulncheck 만 보고 1.25 로 정했다가, 1.26 을 요구하는 golangci-lint 가
# 러너에서 실패했다(이슈 #98). 두 값을 맞추는 것이 주석 한 줄뿐이었다.
#
# 킷의 gates.yml 과 go_min 을 바꾼 tool-versions 를 임시 트리에 두고, 스크립트를 file:// 가짜
# proxy(AI_KIT_GOPROXY)로 실행한다. 네트워크를 쓰지 않는다. 보는 것:
#   · go_min 이 도구들의 가장 높은 go 줄과 패치까지 같으면 rc=0, 다르면 rc=1 이고 맞출 값을 출력한다.
#     낮으면 더 높은 go 를 요구하는 도구를 판정 줄에 이름을 적는다
#   · 견주는 순서는 Go 의 버전 순서다 — 1.26 < 1.26.0 < 1.26.1 (go.dev/doc/toolchain)
#   · 가장 높은 go 줄은 첫 도구가 아니라 마지막 도구에 둔다 — 도구 일부만 보는 스크립트가 통과하지
#     못하게. 도구 이름은 진행 줄(도구마다 출력하는 줄)을 빼고 찾는다. 거기에는 모든 도구가 있다
#   · go install 에 플래그가 붙은 줄도 읽고, 읽지 못한 go install 이 있으면 rc=2(판정 못 함).
#     줄이 아니라 go install 이 나온 자리마다 본다 — 한 줄에 `&&` 로 둘을 이으면 앞의 것이 빠졌다(PR #108 2라운드
#     콜드 리뷰). 높은 go 를 줄의 앞 도구에도, 뒤 도구에도 둔다
#   · 도구의 go.mod 를 못 받거나 go_min 이 없으면 rc=2
#   · 모듈 경로는 패키지 경로의 뒤를 떼며 찾는다(가짜 proxy 에는 모듈 경로에만 둔다)
#   · 도구 모듈이 gofumpt 를 require 하면 그 기준 Go(gofumpt zip 의 internal/govendor/version.txt)도
#     go_min 과 견준다. gofumpt 는 자기 안에 둔 gofmt 로 포맷해서, 그보다 낮은 Go 의 gofmt 와 서로 다른
#     모양을 요구하는 코드가 생긴다(PR #137 1라운드 콜드 리뷰). zip 이나 그 파일을 못 읽으면 rc=2
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

[ -f "$KIT/common/ci/check-go-min.sh" ] || { bad "common/ci/check-go-min.sh 가 없다"; exit 1; }

T=$(mktemp -d)
mkdir -p "$T/kit/common/ci" "$T/kit/common/gate"
cp "$KIT/common/ci/check-go-min.sh" "$T/kit/common/ci/"

# gates.yml 의 `go install <패키지>@${{ steps.tv.outputs.<키> }}` 줄. 스크립트와 따로 읽는다.
tools=$(sed -n 's/.*go install \([^@ ]*\)@\${{ steps\.tv\.outputs\.\([a-z_]*\) }}.*/\1 \2/p' "$KIT/common/ci/gates.yml")
[ "$(printf '%s\n' "$tools" | grep -c .)" -ge 2 ] || { bad "gates.yml 에서 go install 줄을 둘 이상 못 찾았다 — 테스트의 패턴이 낡았나"; exit 1; }
hi=$(printf '%s\n' "$tools" | tail -1 | cut -d' ' -f2)
hipkg=$(printf '%s\n' "$tools" | tail -1 | cut -d' ' -f1)
firstpkg=$(printf '%s\n' "$tools" | head -1 | cut -d' ' -f1)

# 임시 트리의 gates.yml. $1 이 flag 면 $hi 의 go install 에 -v 를 붙이고, unread 면 그 줄의 버전을
# 스크립트가 못 읽는 모양(@latest)으로 바꾼다. joined 면 $hi 의 줄을 지우고 그 설치를 첫 도구의 줄
# 앞에 `&&` 로 잇는다 — 한 줄에 go install 이 둘이다. joinedtail 은 뒤에 잇는다. joinedunread 는
# 앞에 이은 것을 @latest 로 둔다.
yml() {
  awk -v p="go install $hipkg@" -v q="go install $firstpkg@" -v k="$hi" -v mode="${1:-}" '
    mode == "flag"   { i = index($0, p); if (i) $0 = substr($0, 1, i - 1) "go install -v " substr($0, i + 11) }
    mode == "unread" { i = index($0, p); if (i) $0 = substr($0, 1, i - 1) p "latest" }
    mode ~ /^joined/ && index($0, p) { next }
    mode == "joined"       { i = index($0, q); if (i) $0 = substr($0, 1, i - 1) p "${{ steps.tv.outputs." k " }} && " substr($0, i) }
    mode == "joinedtail"   { if (index($0, q)) $0 = $0 " && " p "${{ steps.tv.outputs." k " }}" }
    mode == "joinedunread" { i = index($0, q); if (i) $0 = substr($0, 1, i - 1) p "latest && " substr($0, i) }
    { print }' "$KIT/common/ci/gates.yml" > "$T/kit/common/ci/gates.yml"
}

# 도구마다 가짜 proxy 에 go.mod 를 둔다. $1=$hi 의 go 줄  $2=나머지의 go 줄  $3=빼 둘 도구 키(없으면 비움)
# $4=golangci_lint 의 gofumpt. 비우면 require 하지 않는다. 버전(예: 1.27.0)이면 v0.99.0 을 require 하고, 그
# zip 의 version.txt 를 go<버전> 으로 둔다. nozip 이면 zip 을 두지 않고, nofile 이면 version.txt 없는 zip 을 둔다.
proxy() {
  local pkg key ver mod
  rm -rf "$T/proxy"
  while read -r pkg key; do
    [ "$key" = "${3:-}" ] && continue
    ver=$(sed -n "s/^$key=//p" "$KIT/common/gate/tool-versions")
    mod="${pkg%%/cmd/*}"
    mkdir -p "$T/proxy/$mod/@v"
    { if [ "$key" = "$hi" ]; then printf 'module %s\n\ngo %s\n' "$mod" "$1"; else printf 'module %s\n\ngo %s\n' "$mod" "$2"; fi
      if [ "$key" = golangci_lint ] && [ -n "${4:-}" ]; then
        printf '\nrequire (\n\tgithub.com/example/other v1.0.0\n\tmvdan.cc/gofumpt v0.99.0\n)\n'
      fi
    } > "$T/proxy/$mod/@v/$ver.mod"
  done <<< "$tools"
  case "${4:-}" in
    ''|nozip) ;;
    *) mkdir -p "$T/proxy/mvdan.cc/gofumpt/@v"
       python3 - "$T/proxy/mvdan.cc/gofumpt/@v/v0.99.0.zip" "$4" <<'PY'
import sys, zipfile
path, mode = sys.argv[1:3]
with zipfile.ZipFile(path, "w") as z:
    z.writestr("mvdan.cc/gofumpt@v0.99.0/go.mod", "module mvdan.cc/gofumpt\n")
    if mode != "nofile":
        z.writestr("mvdan.cc/gofumpt@v0.99.0/internal/govendor/version.txt", "go" + mode + "\n")
PY
       ;;
  esac
}

# $1=go_min(비우면 그 줄을 뺀다)
tv() {
  grep -v '^go_min=' "$KIT/common/gate/tool-versions" > "$T/kit/common/gate/tool-versions"
  [ -z "$1" ] || echo "go_min=$1" >> "$T/kit/common/gate/tool-versions"
}

run() { # $1=설명  $2=기대 rc  $3=진행 줄 밖에 있어야 할 글자(비면 안 봄)
  local out rc
  out=$(AI_KIT_GOPROXY="file://$T/proxy" bash "$T/kit/common/ci/check-go-min.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || printf '%s\n' "$out" | grep -v '^  [^?]' | grep -qF -- "$3"; }; then ok "$1 → rc=$rc"
  else bad "$1 → rc=$rc, rc=$2${3:+ 에 「$3」} 여야 한다:"; printf '%s\n' "$out" | cut -c1-160 | sed 's/^/      /'; fi
}

yml
proxy 1.26.0 1.25.0;   tv 1.26.0; run "가장 높은 go 줄 1.26.0 = go_min 1.26.0"           0 "$hi"
proxy 1.26.0 1.25.0;   tv 1.25.0; run "$hi 가 1.26.0 을 요구하는데 go_min 1.25.0"        1 "$hi"
proxy 1.26.0 1.25.0;   tv 1.26;   run "go_min 1.26 은 1.26.0 보다 낮다"                  1 "go_min=1.26.0"
proxy 1.26.0 1.25.0;   tv 1.27.0; run "도구는 1.26.0 까지인데 go_min 1.27.0"             1 "go_min=1.26.0"
proxy 1.26.0 1.25.0;   tv 1.26.1; run "go_min 1.26.1 은 1.26.0 보다 높다"                1 "go_min=1.26.0"
proxy 1.26.1 1.26.0;   tv 1.26.0; run "$hi 가 1.26.1 을 요구하는데 go_min 1.26.0"        1 "go_min=1.26.1"
proxy 1.26.1 1.26.0;   tv 1.26.1; run "가장 높은 go 줄 1.26.1 = go_min 1.26.1"           0 ""
proxy 1.26 1.25.0;     tv 1.26;   run "가장 높은 go 줄이 패치 없는 1.26 = go_min 1.26"    0 ""
proxy 1.26 1.26.0;     tv 1.26;   run "1.26 과 1.26.0 가운데 높은 것은 1.26.0"           1 "go_min=1.26.0"
yml flag
proxy 1.26.0 1.25.0;   tv 1.26.0; run "$hi 의 go install 에 -v 가 붙어도 읽는다"         0 "$hi"
yml unread
proxy 1.26.0 1.25.0;   tv 1.26.0; run "읽지 못한 go install 줄이 있다"                    2 "$hipkg"
yml joined
proxy 1.26.0 1.25.0;   tv 1.26.0; run "한 줄에 go install 이 둘이어도 둘 다 읽는다"        0 "$hi"
yml joinedtail
proxy 1.26.0 1.25.0;   tv 1.26.0; run "한 줄의 뒤 go install 도 읽는다"                   0 "$hi"
yml joinedunread
proxy 1.26.0 1.25.0;   tv 1.26.0; run "한 줄의 go install 둘 가운데 하나를 못 읽는다"      2 "$hipkg"
yml
proxy 1.26.0 1.25.0 "$hi"; tv 1.26.0; run "$hi 의 go.mod 를 못 받음"                    2 "$hi"
proxy 1.26.0 1.25.0;   tv "";     run "tool-versions 에 go_min 없음"                     2 ""
# gofumpt 의 기준 Go. go 줄은 모두 1.26.0 이하이고 golangci_lint 가 gofumpt 를 require 한다.
proxy 1.26.0 1.25.0 "" 1.27.0; tv 1.27.0; run "gofumpt 의 기준 Go 1.27.0 = go_min 1.27.0"            0 "gofumpt"
proxy 1.26.0 1.25.0 "" 1.27.0; tv 1.26.0; run "go 줄은 1.26.0 까지인데 gofumpt 의 기준이 1.27.0"      1 "gofumpt"
proxy 1.26.0 1.25.0 "" 1.27.0; tv 1.27.1; run "go_min 1.27.1 은 gofumpt 의 기준 1.27.0 보다 높다"     1 "go_min=1.27.0"
proxy 1.26.0 1.25.0 "" nozip;  tv 1.27.0; run "gofumpt 의 zip 을 못 받음"                            2 "gofumpt"
proxy 1.26.0 1.25.0 "" nofile; tv 1.27.0; run "gofumpt 의 zip 에 version.txt 가 없음"                2 "version.txt"

rm -rf "$T"
exit $fail
