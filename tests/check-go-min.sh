#!/usr/bin/env bash
# common/ci/check-go-min.sh 가 go_min 과 핀한 Go 도구의 go 줄이 어긋난 것을 잡는가.
#
# 이 테스트가 있는 이유: tool-versions 의 go_min 은 gates.yml 이 go install 로 까는 도구들이 요구하는
# go(그 모듈의 go 줄) 가운데 가장 높은 것과 같아야 한다. 낮으면 도구가 설치되지 않고, 높으면
# gate_go_min_check 의 「핀한 Go 도구가 그보다 낮은 go 로는 설치되지 않습니다」가 거짓이 된다.
# 한때 go_min 을 goimports 와 govulncheck 만 보고 1.25 로 정했다가, 1.26 을 요구하는 golangci-lint 가
# 러너에서 죽었다(이슈 #98). 두 값을 맞추는 것이 주석 한 줄뿐이었다.
#
# 킷의 gates.yml 과 go_min 을 바꾼 tool-versions 를 임시 트리에 두고, 스크립트를 file:// 가짜
# proxy(AI_KIT_GOPROXY)로 돌린다. 네트워크를 쓰지 않는다. 보는 것:
#   · 도구들의 가장 높은 go 줄 = go_min 이면 rc=0, 한 도구가 더 높으면 rc=1 이고 그 도구를 이름댄다,
#     모두 더 낮으면(go_min 이 높으면) rc=1
#   · go 줄의 1.26 과 1.26.0 은 같다
#   · 도구의 go.mod 를 못 받거나 go_min 이 없으면 rc=2(판정 못 함)
#   · 모듈 경로는 패키지 경로의 뒤를 떼며 찾는다(가짜 proxy 에는 모듈 경로에만 둔다)
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

[ -f "$KIT/common/ci/check-go-min.sh" ] || { bad "common/ci/check-go-min.sh 가 없다"; exit 1; }

T=$(mktemp -d)
mkdir -p "$T/kit/common/ci" "$T/kit/common/gate"
cp "$KIT/common/ci/check-go-min.sh" "$KIT/common/ci/gates.yml" "$T/kit/common/ci/"

# gates.yml 의 `go install <패키지>@${{ steps.tv.outputs.<키> }}` 줄. 스크립트와 따로 읽는다.
tools=$(sed -n 's/.*go install \([^@ ]*\)@\${{ steps\.tv\.outputs\.\([a-z_]*\) }}.*/\1 \2/p' "$KIT/common/ci/gates.yml")
[ -n "$tools" ] || { bad "gates.yml 에서 go install 줄을 못 찾았다 — 테스트의 패턴이 낡았나"; exit 1; }
first=$(printf '%s\n' "$tools" | head -1 | cut -d' ' -f2)

# 도구마다 가짜 proxy 에 go.mod 를 둔다. $1=첫 도구의 go 줄  $2=나머지의 go 줄  $3=빼 둘 도구 키(없으면 비움)
proxy() {
  local pkg key ver mod
  rm -rf "$T/proxy"
  while read -r pkg key; do
    [ "$key" = "${3:-}" ] && continue
    ver=$(sed -n "s/^$key=//p" "$KIT/common/gate/tool-versions")
    mod="${pkg%%/cmd/*}"
    mkdir -p "$T/proxy/$mod/@v"
    if [ "$key" = "$first" ]; then printf 'module %s\n\ngo %s\n' "$mod" "$1"; else printf 'module %s\n\ngo %s\n' "$mod" "$2"; fi \
      > "$T/proxy/$mod/@v/$ver.mod"
  done <<< "$tools"
}

# $1=go_min(비우면 그 줄을 뺀다)
tv() {
  grep -v '^go_min=' "$KIT/common/gate/tool-versions" > "$T/kit/common/gate/tool-versions"
  [ -z "$1" ] || echo "go_min=$1" >> "$T/kit/common/gate/tool-versions"
}

run() { # $1=설명  $2=기대 rc  $3=출력에 있어야 할 글자(비면 안 봄)
  local out rc
  out=$(AI_KIT_GOPROXY="file://$T/proxy" bash "$T/kit/common/ci/check-go-min.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && { [ -z "$3" ] || printf '%s\n' "$out" | grep -qF -- "$3"; }; then ok "$1 → rc=$rc"
  else bad "$1 → rc=$rc, rc=$2${3:+ 에 「$3」} 여야 한다:"; printf '%s\n' "$out" | cut -c1-140 | sed 's/^/      /'; fi
}

proxy 1.26.0 1.25.0;   tv 1.26; run "가장 높은 go 줄 1.26.0 = go_min 1.26"           0 ""
proxy 1.26.0 1.25.0;   tv 1.25; run "$first 가 1.26.0 을 요구하는데 go_min 1.25"     1 "$first"
proxy 1.26.0 1.25.0;   tv 1.27; run "도구는 1.26.0 까지인데 go_min 1.27"             1 ""
proxy 1.26 1.25;       tv 1.26; run "go 줄 1.26(패치 없음) = go_min 1.26"            0 ""
proxy 1.26.0 1.26.0;   tv 1.26; run "모든 도구가 1.26.0 = go_min 1.26"               0 ""
proxy 1.26.0 1.25.0 "$first"; tv 1.26; run "$first 의 go.mod 를 못 받음"            2 "$first"
proxy 1.26.0 1.25.0;   tv "";   run "tool-versions 에 go_min 없음"                   2 ""

rm -rf "$T"
exit $fail
