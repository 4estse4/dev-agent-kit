#!/usr/bin/env bash
# tool-versions 의 go_min 이 핀한 Go 도구가 요구하는 go 와 맞는지 본다.
#
# 왜 이게 필요한가 — go_min 은 gates.yml 이 go install 로 까는 도구들이 요구하는 go(그 모듈의
# go 줄) 가운데 가장 높은 것과 같아야 한다. 낮으면 최소 버전 검사를 지난 레포가 그 도구의 설치에서
# 「requires go >= …」로 죽고, 높으면 gate_go_min_check 가 드는 이유(핀한 Go 도구가 그보다 낮은
# go 로는 설치되지 않는다)가 거짓이 된다. 한때 goimports 와 govulncheck 만 보고 1.25 로 정했다가
# 1.26 을 요구하는 golangci-lint 가 러너에서 죽었다(이슈 #98). 두 값을 맞추는 것이 주석뿐이었다.
#
# 도구 목록은 gates.yml 의 `go install <패키지>@${{ steps.tv.outputs.<키> }}` 줄에서 읽는다 — CI 가
# 실제로 까는 목록이라 따로 적지 않는다. 모듈의 go 줄은 Go 모듈 proxy 의 <모듈>/@v/<버전>.mod 에
# 있고, 모듈 경로는 패키지 경로의 뒤를 하나씩 떼며 처음 받아지는 것이다. proxy 의 그 파일은
# 버전마다 바뀌지 않으므로 결과가 달라지는 것은 핀이나 go install 줄이 바뀔 때뿐이다.
#
#   check-go-min.sh        AI_KIT_GOPROXY 로 proxy 주소를 바꾼다(기본 https://proxy.golang.org)
#
# 종료코드: 0 맞음 · 1 어긋남 · 2 판정 못 함(조회 실패 · 키 없음 · go install 줄 없음).
# 판정 못 한 것을 통과로 치지 않는다 — check-action-pins.sh 와 같다.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TV="$SELF_DIR/../gate/tool-versions"
G="$SELF_DIR/gates.yml"
PROXY="${AI_KIT_GOPROXY:-https://proxy.golang.org}"

command -v curl >/dev/null 2>&1 || { echo "check-go-min: curl 이 필요합니다" >&2; exit 2; }
[ -f "$TV" ] && [ -f "$G" ] || { echo "check-go-min: $TV 또는 $G 가 없습니다" >&2; exit 2; }

min=$(sed -n 's/^go_min=//p' "$TV" | head -1)
[ -n "$min" ] || { echo "check-go-min: tool-versions 에 go_min 이 없습니다" >&2; exit 2; }
rows=$(sed -n 's/.*go install \([^@ ]*\)@\${{ steps\.tv\.outputs\.\([a-z_]*\) }}.*/\1 \2/p' "$G")
[ -n "$rows" ] || { echo "check-go-min: gates.yml 에서 go install 줄을 찾지 못했습니다" >&2; exit 2; }

norm() { case "$1" in *.*.*) echo "$1" ;; *) echo "$1.0" ;; esac; }   # go 1.26 과 1.26.0 은 같다

failed=0; needs=""
while read -r pkg key; do
  ver=$(sed -n "s/^$key=//p" "$TV" | head -1)
  [ -n "$ver" ] || { echo "  ? $key — tool-versions 에 없습니다" >&2; failed=1; continue; }
  m="$pkg"; gomod=""
  while :; do
    gomod=$(curl -fsS --max-time 30 "$PROXY/$m/@v/$ver.mod" 2>/dev/null) && break
    gomod=""
    case "$m" in */*) m="${m%/*}" ;; *) break ;; esac
  done
  need=$(printf '%s\n' "$gomod" | awk '$1 == "go" { print $2; exit }')
  [ -n "$need" ] || { echo "  ? $key ($pkg@$ver) — 모듈의 go.mod 에서 go 줄을 받지 못했습니다" >&2; failed=1; continue; }
  echo "  $key $ver ($m) go $need"
  needs+="$(norm "$need")	$key	$need"$'\n'
done <<< "$rows"

[ "$failed" = 0 ] || { echo "check-go-min — 조회 실패가 있어 판정할 수 없습니다" >&2; exit 2; }

top=$(printf '%s' "$needs" | sort -V | tail -1)
max="${top%%	*}"; rest="${top#*	}"; maxkey="${rest%%	*}"; maxraw="${rest#*	}"
want=$(echo "$max" | awk -F. '{ print $1 "." $2 }')   # go_min 은 메이저.마이너로 적는다
if [ "$(norm "$min")" = "$max" ]; then
  echo "check-go-min ✓ go_min=$min · 도구가 요구하는 가장 높은 go 는 $maxkey 의 go $maxraw"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$(norm "$min")" "$max" | sort -V | head -1)" = "$(norm "$min")" ]; then
  over=$(printf '%s' "$needs" | while IFS=$'\t' read -r n k r; do
    [ "$(printf '%s\n%s\n' "$(norm "$min")" "$n" | sort -V | tail -1)" = "$(norm "$min")" ] || printf '%s(go %s) ' "$k" "$r"
  done)
  echo "check-go-min ✗ go_min 이 낮습니다(go_min=$min) — 더 높은 go 를 요구하는 도구: ${over% }. 이렇게 올리세요: go_min=$want"
else
  echo "check-go-min ✗ go_min 이 도구가 요구하는 가장 높은 go($maxkey 의 go $maxraw)보다 높습니다(go_min=$min) — gate_go_min_check 가 드는 이유(핀한 Go 도구가 그보다 낮은 go 로는 설치되지 않는다)가 거짓이 됩니다. 이렇게 맞추세요: go_min=$want"
fi
exit 1
