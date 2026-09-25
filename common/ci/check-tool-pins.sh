#!/usr/bin/env bash
# 킷의 게이트 도구 핀(common/gate/tool-versions)이 최신보다 뒤처졌는지 검사한다.
#
# 왜 이게 필요한가 — Dependabot 은 tool-versions 를 생태계로 알아보지 못하고, check-action-pins.sh 는 워크플로의
# 액션만 본다. 그래서 도구 핀이 낡아도 아무도 말해 주지 않았다(이슈 #110). 주간 워크플로가 이것을 부른다.
#
# 최신은 킷이 그 도구를 받는 곳에서 읽는다.
#   Go 도구  gates.yml 의 `go install [플래그…] <패키지>@${{ steps.tv.outputs.<키> }}` 줄에서 도구와 키를 읽고
#            (check-go-min.sh 와 같은 식), `go list -m <모듈>@latest` 에 묻는다. go 명령은 retract 된 버전을 빼고
#            고르므로(go.dev/ref/mod 의 모듈 프록시 절) 프록시 목록의 가장 높은 버전과 다를 수 있다. 모듈 경로는
#            패키지 경로의 뒤를 하나씩 떼며 처음 답하는 것이다. 떼는 것은 go 가 「그 경로는 모듈이 아니다」라고
#            답할 때뿐이고, 다른 실패는 판정 못 함이다
#   ruff     PyPI 의 JSON API(`/pypi/ruff/json` 의 info.version)
#   ktlint   GitHub 의 releases/latest(tag_name). gates.yml · install-tools.sh · lib.sh 도 이 레포의 릴리스에서
#            받는다(tests/check-tool-pins.sh 가 대조한다). 리다이렉트를 따라가지 않는다 — 레포가 옮겨지면 API 가
#            301 을 주고, 출력이 「레포가 옮겨졌습니다」와 새 주소를 말하며 판정 못 함이 되어 주간 워크플로가
#            실패한다. 일시 리다이렉트(302 · 307)도 따라가지 않는다. 킷은 레포가 pinterest/ktlint 에서
#            옮겨진 뒤에도 옛 경로에서 받고 있었고, 따라가는 동안에는 그것이 드러나지 않았다(이슈 #131)
# go_min 은 도구가 아니다 — check-go-min.sh 가 PR 마다 본다.
#
#   check-tool-pins.sh     AI_KIT_PYPI_URL(기본 https://pypi.org) · AI_KIT_GITHUB_API(기본 https://api.github.com) ·
#                          GOPROXY(go 의 것)로 조회 주소를 바꾼다. GH_TOKEN 이 있으면 GitHub 조회에 쓴다
#
# 종료코드: 0 최신 · 1 뒤처짐 · 2 판정 못 함(조회 실패 · 출처가 없는 키 · gates.yml 이 설치하는데 tool-versions 에
# 없는 키). 판정하지 못한 것을 최신으로 처리하지 않는다 — check-action-pins.sh 와 같다.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TV="$SELF_DIR/../gate/tool-versions"
G="$SELF_DIR/gates.yml"
PYPI="${AI_KIT_PYPI_URL:-https://pypi.org}"
GHAPI="${AI_KIT_GITHUB_API:-https://api.github.com}"

for c in curl go python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "check-tool-pins: $c 가 필요합니다" >&2; exit 2; }
done
[ -f "$TV" ] && [ -f "$G" ] || { echo "check-tool-pins: $TV 또는 $G 가 없습니다" >&2; exit 2; }

# Go 도구가 아닌 것의 출처. 한 줄에 <키> <pypi|github> <이름>
OTHER="ruff pypi ruff
ktlint github ktlint/ktlint"

pat='go install \(-[^ ]* \)*\([^@ ]*\)@\${{ steps\.tv\.outputs\.\([a-z_]*\) }}'
gorows=$(grep -v '^[[:space:]]*#' "$G" | grep -o "$pat" | sed "s/^$pat\$/\2 \3/" | sort -u)   # <패키지> <키>
keys=$(sed -n 's/^\([a-z_][a-z_0-9]*\)=.*/\1/p' "$TV" | grep -vx go_min)

auth=(); [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT   # go list 를 모듈 밖에서 부른다

behind=0; failed=0; checked=0
while read -r pkg key; do
  [ -n "$key" ] || continue
  printf '%s\n' "$keys" | grep -qx "$key" \
    || { echo "  ? $key ($pkg) — gates.yml 이 설치하는데 tool-versions 에 없습니다" >&2; failed=1; }
done <<< "$gorows"

for key in $keys; do
  cur=$(sed -n "s/^$key=//p" "$TV" | head -1)
  pkg=$(printf '%s\n' "$gorows" | awk -v k="$key" '$2 == k { print $1; exit }')
  other=$(printf '%s\n' "$OTHER" | awk -v k="$key" '$1 == k { print $2, $3; exit }')
  latest=""
  if [ -n "$pkg" ]; then
    # 경로의 뒤를 떼는 것은 「그 경로는 모듈이 아니다」일 때만이다. go 는 모듈이 아닌 경로에 프록시로 묻든
    # direct 로 묻든 `no matching versions` 로 답한다. 그 밖의 실패(프록시의 5xx · 연결 실패)에서 떼면
    # golangci-lint 는 /v2 를 뗀 v1 모듈의 최신을 받아 최신이라고 판정했다(PR #132 1라운드 콜드 리뷰).
    m="$pkg"; why=""
    while :; do
      if latest=$(cd "$work" && go list -m -f '{{.Version}}' "$m@latest" 2>"$work/err") && [ -n "$latest" ]; then
        break
      fi
      latest=""
      grep -q 'no matching versions' "$work/err" || { why=$(head -1 "$work/err"); break; }
      case "$m" in */*) m="${m%/*}" ;; *) break ;; esac
    done
    src="go list -m $m@latest${why:+: $why}"
  elif [ -n "$other" ]; then
    kind=${other%% *}; name=${other#* }; why=""
    case "$kind" in
      pypi)   latest=$(curl -fsSL --max-time 30 "$PYPI/pypi/$name/json" 2>/dev/null \
                       | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null) ;;
      github)
        # 리다이렉트를 따라가지 않고 상태를 받는다. 301 · 308 이면 레포가 옮겨졌다고 말한다 — 안 그러면 API 가
        # 응답하지 않은 것과 같은 글이 되어, 받는 사람이 직접 조회해 봐야 안다(PR #134 1라운드 콜드 리뷰).
        # 끝 줄은 「상태 Location」 한 줄이다. 둘을 줄로 나누면 Location 이 빌 때 $( ) 가 그 빈 줄을 떼어
        # 상태 줄이 밀린다. file:// 은 상태가 000 이다(테스트의 가짜 응답).
        resp=$(curl -sS --max-time 30 ${auth[@]+"${auth[@]}"} -w '\n%{http_code} %{redirect_url}' \
                 "$GHAPI/repos/$name/releases/latest" 2>"$work/err"); crc=$?
        last=$(printf '%s\n' "$resp" | tail -1); code=${last%% *}
        case "$crc:$code" in
          0:200|0:000) latest=$(printf '%s\n' "$resp" | sed '$d' \
                                | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null) ;;
          0:301|0:308) why="레포가 옮겨졌습니다(HTTP $code → ${last#* })" ;;
          0:*)         why="HTTP $code" ;;
          *)           why=$(head -1 "$work/err") ;;
        esac ;;
    esac
    src="$kind $name${why:+: $why}"
  else
    echo "  ? $key — 최신을 읽을 출처가 없습니다(gates.yml 의 go install 줄에도, 이 스크립트의 표에도 없다)" >&2
    failed=1; continue
  fi
  [ -n "$latest" ] || { echo "  ? $key ($src) — 최신을 읽지 못했습니다" >&2; failed=1; continue; }
  checked=$((checked+1))
  # 새 값은 tool-versions 의 모양(v 접두 유무)을 따른다. gates.yml · lib.sh 는 그 값을 @ 뒤에 그대로 붙인다.
  c=${cur#v}; l=${latest#v}
  case "$cur" in v*) show="v$l" ;; *) show="$l" ;; esac
  if [ "$c" != "$l" ] && [ "$(printf '%s\n%s\n' "$c" "$l" | sort -V | tail -1)" = "$l" ]; then
    echo "  ✗ $key  $cur → $show"; behind=1
  fi
done

if [ "$failed" = 1 ]; then
  echo "check-tool-pins — 최신을 읽지 못한 도구가 있어 판정할 수 없습니다" >&2; exit 2
fi
if [ "$behind" = 1 ]; then
  echo ""
  echo "위 핀이 뒤처졌습니다. common/gate/tool-versions 를 올리고 커밋하세요 — Dependabot 은 이 파일을 보지 않습니다."
  echo "올리기 전에 볼 것: ruff 는 올리면 규칙이 바뀔 수 있으니 검사 대상 Python 코드가 있는 레포에서 실행해 봅니다."
  echo "Go 도구를 올리면 그 PR 에서 check-go-min.sh 가 go_min 과 견줍니다."
  exit 1
fi
echo "check-tool-pins ✓ ${checked}개 도구가 최신입니다"
