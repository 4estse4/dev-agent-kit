#!/usr/bin/env bash
# tool-versions 의 go_min 이 핀한 Go 도구가 요구하는 go 와, 그 도구가 쓰는 gofumpt 의 기준 Go 와 맞는지 본다.
#
# 왜 이게 필요한가 — go_min 은 아래 둘 가운데 가장 높은 것과 같아야 한다. 높으면 gate_go_min_check 가
# 드는 이유가 거짓이 된다.
#   · gates.yml 이 go install 로 설치하는 도구들이 요구하는 go(그 모듈의 go 줄). 낮으면 최소 버전 검사를
#     지난 레포가 그 도구의 설치에서 「requires go >= …」로 실패한다. 한때 goimports 와 govulncheck 만 보고
#     1.25 로 정했다가 1.26 을 요구하는 golangci-lint 가 러너에서 실패했다(이슈 #98). 두 값을 맞추는 것이
#     주석뿐이었다.
#   · 그 도구 모듈이 require 하는 gofumpt(golangci-lint 의 formatter)의 기준 Go. gofumpt 는 자기 안에 둔
#     gofmt 로 포맷해서, 그보다 낮은 Go 의 gofmt 와 서로 다른 모양을 요구하는 코드가 생긴다. 그 코드는
#     게이트의 gofmt · goimports 와 golangci-lint 가운데 한쪽에서 늘 실패한다. golangci-lint v2.14.0 의
#     gofumpt v0.12.0 이 Go 1.27 을 기준으로 해서, go 1.26 모듈에서 여러 줄 composite literal 둘을 반환하는
#     return 이 그랬다(PR #137 1라운드 콜드 리뷰). 이 기준은 go 줄에 보이지 않는다 — 그 golangci-lint 의
#     go 줄은 1.26.0 이다. gofumpt 모듈 zip 의 internal/govendor/version.txt 에서 읽는다.
#
# 같다는 것은 패치까지 같다는 것이다. Go 의 버전 순서로 1.27 < 1.27.0 < 1.27.1 이고
# (go.dev/doc/toolchain), sort -V 가 이 형태들을 그 순서대로 놓는다. 그래서 go_min 에는 가장 높은
# 것을 그대로 적는다. 패치가 없는 go 줄을 계열로 받아 주는 것은 레포 쪽을 보는
# gate_go_min_check 의 일이다.
#
# go_min 에 0 이 아닌 패치가 들어가는 날에는 gate_go_min_check 의 전제를 다시 본다. 그쪽은 패치
# 없는 go 줄을 계열로 통과시키는데, 그 레포에 setup-go 가 설치하는 것은 러너 캐시의 그 계열 패치이고
# 그것이 go_min 의 패치보다 낮으면 검사를 지나고도 도구 설치가 「requires go >= …」로 실패한다.
#
# 도구 목록은 gates.yml 의 `go install [플래그…] <패키지>@${{ steps.tv.outputs.<키> }}` 에서
# 읽는다 — CI 가 실제로 설치하는 목록이라 따로 적지 않는다. 주석이 아닌 줄에 이 모양으로 못 읽은
# go install 이 있으면 판정하지 않는다. 도구 일부만 보고 내린 판정이 #98 의 모양이다.
# 모듈의 go 줄은 Go 모듈 proxy 의 <모듈>/@v/<버전>.mod 에 있고, 모듈 경로는 패키지 경로의 뒤를
# 하나씩 떼며 처음 받아지는 것이다. gofumpt 는 그 .mod 의 require 에서 버전을 읽고, 같은 proxy 의
# mvdan.cc/gofumpt/@v/<버전>.zip 을 받아 unzip 으로 version.txt 만 꺼낸다. proxy 의 그 파일들은 버전마다
# 바뀌지 않으므로 결과가 달라지는 것은 핀이나 go install 줄이 바뀔 때뿐이다.
#
#   check-go-min.sh        AI_KIT_GOPROXY 로 proxy 주소를 바꾼다(기본 https://proxy.golang.org)
#
# 종료코드: 0 맞음 · 1 어긋남 · 2 판정 못 함(조회 실패 · 키 없음 · go install 줄 없음 · 못 읽은 go install ·
# gofumpt 의 zip 이나 version.txt 를 못 읽음).
# 판정 못 한 것을 통과로 처리하지 않는다 — check-action-pins.sh 와 같다.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TV="$SELF_DIR/../gate/tool-versions"
G="$SELF_DIR/gates.yml"
PROXY="${AI_KIT_GOPROXY:-https://proxy.golang.org}"

for c in curl unzip; do
  command -v "$c" >/dev/null 2>&1 || { echo "check-go-min: $c 이 필요합니다" >&2; exit 2; }
done
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT   # gofumpt 의 zip 을 받는 자리
[ -f "$TV" ] && [ -f "$G" ] || { echo "check-go-min: $TV 또는 $G 가 없습니다" >&2; exit 2; }

min=$(sed -n 's/^go_min=//p' "$TV" | head -1)
[ -n "$min" ] || { echo "check-go-min: tool-versions 에 go_min 이 없습니다" >&2; exit 2; }
pat='go install \(-[^ ]* \)*\([^@ ]*\)@\${{ steps\.tv\.outputs\.\([a-z_]*\) }}'
body=$(grep -v '^[[:space:]]*#' "$G")
# 줄이 아니라 나온 것마다 읽는다. 한 줄에 `&&` 로 둘을 이으면 줄 단위로는 하나만 뽑혔다.
rows=$(printf '%s\n' "$body" | grep -o "$pat" | sed "s/^$pat\$/\2 \3/")
[ -n "$rows" ] || { echo "check-go-min: gates.yml 에서 go install 줄을 찾지 못했습니다" >&2; exit 2; }
# 읽은 것을 지우고도 go install 이 남는 줄. 한 줄에 둘이 있고 하나만 읽힌 줄도 여기 해당한다.
unread=$(printf '%s\n' "$body" | while IFS= read -r l; do
  case "$l" in (*'go install '*) ;; (*) continue ;; esac
  case "$(printf '%s\n' "$l" | sed "s/$pat//g")" in (*'go install '*) printf '%s\n' "$l" ;; esac
done)
if [ -n "$unread" ]; then
  echo "check-go-min: gates.yml 에 도구와 키를 읽지 못한 go install 이 있어 판정할 수 없습니다 — go install [플래그…] <패키지>@\${{ steps.tv.outputs.<키> }} 모양이어야 합니다" >&2
  printf '%s\n' "$unread" | sed 's/^[[:space:]]*/  ? /' >&2
  exit 2
fi

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
  needs+="$need	$key"$'\n'
  # 그 모듈이 gofumpt 를 require 하면 gofumpt 의 기준 Go 도 본다(머리 주석). require 블록 안의 줄만
  # 읽는다. golangci-lint v2 의 go.mod 는 gofumpt 를 늘 블록 안에 두었다(PR #137 2라운드 콜드 리뷰).
  fv=$(printf '%s\n' "$gomod" | awk '$1 == "mvdan.cc/gofumpt" { print $2; exit }')
  [ -n "$fv" ] || continue
  fkey="$key 의 gofumpt $fv"
  if ! curl -fsS --max-time 60 -o "$work/gofumpt.zip" "$PROXY/mvdan.cc/gofumpt/@v/$fv.zip" 2>/dev/null; then
    echo "  ? $fkey — 모듈 zip 을 받지 못했습니다" >&2; failed=1; continue
  fi
  base=$(unzip -p "$work/gofumpt.zip" "mvdan.cc/gofumpt@$fv/internal/govendor/version.txt" 2>/dev/null | head -1 | tr -d '[:space:]')
  base="${base#go}"
  case "$base" in
    [0-9]*.[0-9]*) ;;
    *) echo "  ? $fkey — zip 의 internal/govendor/version.txt 에서 Go 버전을 읽지 못했습니다" >&2; failed=1; continue ;;
  esac
  echo "  $fkey (mvdan.cc/gofumpt) gofmt 의 기준 go $base"
  needs+="$base	$fkey"$'\n'
done <<< "$rows"

[ "$failed" = 0 ] || { echo "check-go-min — 조회 실패가 있어 판정할 수 없습니다" >&2; exit 2; }

top=$(printf '%s' "$needs" | sort -V | tail -1)
max="${top%%	*}"; maxkey="${top#*	}"
if [ "$min" = "$max" ]; then
  echo "check-go-min ✓ go_min=$min · 도구가 요구하는 가장 높은 go 는 $maxkey 의 go $max"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$min" "$max" | sort -V | head -1)" = "$min" ]; then
  over=$(printf '%s' "$needs" | while IFS=$'\t' read -r n k; do
    [ "$(printf '%s\n%s\n' "$min" "$n" | sort -V | tail -1)" = "$min" ] || printf '%s(go %s) ' "$k" "$n"
  done)
  echo "check-go-min ✗ go_min 이 낮습니다(go_min=$min) — 더 높은 go 를 요구하는 도구: ${over% }. 이렇게 올리세요: go_min=$max"
else
  echo "check-go-min ✗ go_min 이 도구가 요구하는 가장 높은 go($maxkey 의 go $max)보다 높습니다(go_min=$min) — gate_go_min_check 가 드는 이유(그보다 낮은 go 로는 핀한 Go 도구가 설치되지 않거나 gofumpt 와 포맷이 어긋난다)가 거짓이 됩니다. 이렇게 맞추세요: go_min=$max"
fi
exit 1
