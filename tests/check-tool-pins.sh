#!/usr/bin/env bash
# common/ci/check-tool-pins.sh 가 tool-versions 의 도구 핀을 최신과 견주고, 판정하지 못한 것을 최신으로 세지 않는다.
#
# 이 테스트가 있는 이유: tool-versions 의 핀이 최신보다 뒤처졌는지 보는 것이 킷에 없었다(이슈 #110). 이슈 #36 은
# 그 검사가 생겼다는 전제에서 시작했지만 그 PR(#35)은 머지되지 않았다. Dependabot 은 그 파일을 생태계로 알아보지 못한다.
#
# 킷의 스크립트 · gates.yml · tool-versions 를 임시 트리에 두고 네트워크 없이 실행한다. PyPI 와 GitHub 의 응답은
# file:// 로(AI_KIT_PYPI_URL · AI_KIT_GITHUB_API), go 는 모듈 경로마다 정해 둔 최신을 답하는 가짜로 둔다. 가짜 go 는
# 모듈 경로가 아니면 진짜 go 처럼 `no matching versions` 로 실패한다. 보는 것:
#   · 모든 핀이 최신이면 rc=0. go_min 은 도구가 아니라 견주지 않는다
#   · Go 도구 하나 · ruff · ktlint 가 뒤처지면 rc=1 과 그 줄. 새 값은 tool-versions 의 모양(v 접두 유무)을 따른다
#   · 핀이 최신보다 높으면 뒤처진 것이 아니다
#   · Go 도구의 모듈 경로는 gates.yml 의 패키지 경로에서 뒤를 떼며 찾는다
#   · 최신을 못 읽으면(PyPI · GitHub 응답 없음, go list 실패) · 출처가 없는 키가 있으면 · gates.yml 이 설치하는
#     도구의 키가 tool-versions 에 없으면 rc=2. 뒤처진 도구가 함께 있어도 rc=2 다
#
# ktlint 레포가 pinterest/ktlint 에서 옮겨진 뒤에도 킷은 옛 경로에서 받고 있었고, 조회는 리다이렉트를 따라가서 옮겨진
# 것이 드러나지 않았다(이슈 #131). 그래서 둘을 더 본다:
#   · GitHub API 가 301 을 주면 rc=2 이고, 출력이 레포가 옮겨졌다고 말한다. 301 은 file:// 로 줄 수 없어 로컬
#     HTTP 서버를 둔다. 그 Location 에는 정상 응답이 있어서, 따라가면 rc=0 이 된다. 서버에 닿지 못하거나 요청
#     경로가 서버의 경로와 달라도 rc=2 이므로, 301 을 받았는지는 그 글로 확인한다(PR #134 1라운드 리뷰)
#   · 킷이 ktlint 를 받는 URL(추적 파일, docs/dev-log.md 는 뺀다)이 모두 이 스크립트가 최신을 읽는 레포를 가리킨다.
#     gates.yml · install-tools.sh · lib.sh 에 각각 하나 이상 있어야 한다 — 식이 못 찾아 0 건이면 대조할 것이 없어
#     통과하므로. git grep 이 실패하면 통과로 세지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

[ -f "$KIT/common/ci/check-tool-pins.sh" ] || { bad "common/ci/check-tool-pins.sh 가 없다"; exit 1; }

T=$(mktemp -d)
mkdir -p "$T/kit/common/ci" "$T/kit/common/gate" "$T/bin"
cp "$KIT/common/ci/check-tool-pins.sh" "$KIT/common/ci/gates.yml" "$T/kit/common/ci/"
TV="$T/kit/common/gate/tool-versions"

# 가짜 go. `go list -m -f {{.Version}} <모듈>@latest` 에 $GOFAKE/<모듈>/latest 의 값을 답한다. 부른 경로를 적는다.
# 모듈이 아닌 경로에는 진짜 go 처럼 `no matching versions` 로 실패한다. $GOFAKE/<모듈>/error 가 있으면 그 글로
# 실패한다(프록시의 5xx 나 연결 실패).
cat > "$T/bin/go" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GOFAKE_LOG"
[ "$1 $2" = "list -m" ] || { echo "go 대역: 모르는 호출: $*" >&2; exit 2; }
q="${!#}"; m="${q%@latest}"
[ "$q" != "$m" ] || { echo "go 대역: @latest 가 아닌 질의: $q" >&2; exit 2; }
[ -f "$GOFAKE/$m/error" ] && { cat "$GOFAKE/$m/error" >&2; exit 1; }
[ -f "$GOFAKE/$m/latest" ] || { echo "go: module $m: no matching versions for query \"latest\"" >&2; exit 1; }
cat "$GOFAKE/$m/latest"
EOF
chmod +x "$T/bin/go"

# 한 경우의 환경을 만든다. 인자=「키=최신」. 적지 않은 도구의 최신은 지금 핀과 같다.
# 특수 값: 「ruff=-」 PyPI 응답 없음 · 「ktlint=-」 GitHub 응답 없음 · 「golangci_lint=-」 go list 실패.
# 「+키=값」 은 tool-versions 에 줄을 더한다.
setup() {
  local a k v pin
  rm -rf "$T/pypi" "$T/gh" "$T/goproxy"; : > "$T/golog"
  cp "$KIT/common/gate/tool-versions" "$TV"
  mkdir -p "$T/pypi/pypi/ruff" "$T/gh/repos/ktlint/ktlint/releases" "$T/goproxy"
  pin() { sed -n "s/^$1=//p" "$TV" | head -1; }
  printf '{"info": {"version": "%s"}}\n' "$(pin ruff)" > "$T/pypi/pypi/ruff/json"
  printf '{"tag_name": "%s"}\n' "$(pin ktlint)" > "$T/gh/repos/ktlint/ktlint/releases/latest"
  for k in golang.org/x/tools:goimports golang.org/x/vuln:govulncheck github.com/golangci/golangci-lint/v2:golangci_lint; do
    mkdir -p "$T/goproxy/${k%%:*}"; pin "${k##*:}" > "$T/goproxy/${k%%:*}/latest"
  done
  for a in "$@"; do
    case "$a" in +*) printf '%s\n' "${a#+}" >> "$TV"; continue ;; esac
    k="${a%%=*}"; v="${a#*=}"; p=""
    case "$k" in
      goimports)     p=golang.org/x/tools ;;
      govulncheck)   p=golang.org/x/vuln ;;
      golangci_lint) p=github.com/golangci/golangci-lint/v2 ;;
    esac
    case "$k" in
      ruff)   if [ "$v" = - ]; then rm "$T/pypi/pypi/ruff/json"; else printf '{"info": {"version": "%s"}}\n' "$v" > "$T/pypi/pypi/ruff/json"; fi ;;
      ktlint) if [ "$v" = - ]; then rm "$T/gh/repos/ktlint/ktlint/releases/latest"; else printf '{"tag_name": "%s"}\n' "$v" > "$T/gh/repos/ktlint/ktlint/releases/latest"; fi ;;
      goimports|govulncheck|golangci_lint) if [ "$v" = - ]; then rm -rf "$T/goproxy/$p"; else printf '%s\n' "$v" > "$T/goproxy/$p/latest"; fi ;;
      tvdel) sed -i.bak "/^$v=/d" "$TV" && rm -f "$TV.bak" ;;
      # golangci-lint 의 v2 모듈 조회만 서버 오류로 실패하고, /v2 를 뗀 v1 모듈은 실제처럼 있다.
      v2down) printf 'go: github.com/golangci/golangci-lint/v2@latest: reading https://proxy.golang.org/github.com/golangci/golangci-lint/v2/@v/list: 503 Service Unavailable\n' > "$T/goproxy/github.com/golangci/golangci-lint/v2/error"
              mkdir -p "$T/goproxy/github.com/golangci/golangci-lint"; echo v1.64.8 > "$T/goproxy/github.com/golangci/golangci-lint/latest" ;;
    esac
  done
}
# GHAPI_T 가 있으면 GitHub 조회를 그 주소로 보낸다(아래 301 경우).
run() {
  out=$(PATH="$T/bin:$PATH" GOFAKE="$T/goproxy" GOFAKE_LOG="$T/golog" \
        AI_KIT_PYPI_URL="file://$T/pypi" AI_KIT_GITHUB_API="${GHAPI_T:-file://$T/gh}" GH_TOKEN= \
        bash "$T/kit/common/ci/check-tool-pins.sh" 2>&1); rc=$?
}
# $1=설명  $2=기대 rc  $3=출력에 있어야 할 글자(비면 안 봄)  $4=출력에 없어야 할 글자(비면 안 봄)  나머지=setup 인자
case_() {
  local what="$1" want="$2" must="$3" mustnot="$4"; shift 4
  setup "$@"; run
  if [ "$rc" != "$want" ]; then bad "$what → rc=$rc, rc=$want 여야 한다:"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
  elif [ -n "$must" ] && ! printf '%s\n' "$out" | grep -qF -- "$must"; then bad "$what → rc=$rc 인데 「${must}」 이 출력에 없다:"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
  elif [ -n "$mustnot" ] && printf '%s\n' "$out" | grep -qF -- "$mustnot"; then bad "$what → 「${mustnot}」 이 출력에 있다:"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /'
  else ok "$what → rc=$rc"; fi
}

gl=$(sed -n 's/^golangci_lint=//p' "$KIT/common/gate/tool-versions")
rf=$(sed -n 's/^ruff=//p' "$KIT/common/gate/tool-versions")
kl=$(sed -n 's/^ktlint=//p' "$KIT/common/gate/tool-versions")
case_ "모든 핀이 최신"                 0 "✓" "go_min"
case_ "golangci_lint 가 뒤처짐(v 접두)" 1 "golangci_lint  $gl → v9.9.9" "" golangci_lint=v9.9.9
case_ "ruff 가 뒤처짐(v 접두 없음)"     1 "ruff  $rf → 99.0.0" "" ruff=99.0.0
case_ "ktlint 태그에 v 가 붙어 옴"      1 "ktlint  $kl → 99.1.0" "→ v99.1.0" ktlint=v99.1.0
case_ "핀이 최신보다 높음"              0 "" "✗" ruff=0.0.1
case_ "PyPI 응답 없음"                  2 "ruff" "" ruff=-
case_ "GitHub 응답 없음"                2 "ktlint" "" ktlint=-
case_ "go list 가 모든 경로에서 실패"   2 "golangci_lint" "" golangci_lint=-
case_ "v2 조회만 서버 오류(v1 모듈은 있음)" 2 "503" "✓" v2down=1
case_ "뒤처진 것과 못 읽은 것이 함께"   2 "golangci_lint" "" golangci_lint=v9.9.9 ruff=-
case_ "출처가 없는 키"                  2 "foo" "" +foo=1.0.0
case_ "gates.yml 이 설치하는 도구의 키가 tool-versions 에 없음" 2 "govulncheck" "" tvdel=govulncheck

# 모듈 경로: 패키지 경로로 먼저 묻고, 실패하면 뒤를 떼어 모듈 경로에서 답을 받는다.
setup; run
if grep -q 'list -m .*golang.org/x/tools/cmd/goimports@latest' "$T/golog" && grep -q 'list -m .*golang.org/x/tools@latest' "$T/golog"; then
  ok "모듈 경로는 패키지 경로(golang.org/x/tools/cmd/goimports)에서 뒤를 떼며 찾는다"
else
  bad "go 에 물은 경로가 패키지 경로에서 모듈 경로로 줄지 않았다:"; sed 's/^/      /' "$T/golog" | head -6
fi

# 레포가 옮겨짐: API 가 releases/latest 에 301 을 주고, Location 에서는 지금 핀을 최신으로 답한다.
cat > "$T/moved.py" <<'PY'
import http.server, json, os, sys
port_file, tag = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/repos/ktlint/ktlint/releases/latest":
            code, body = 301, {"message": "Moved Permanently", "url": "/repositories/1/releases/latest"}
        elif self.path == "/repositories/1/releases/latest":
            code, body = 200, {"tag_name": tag}
        else:
            code, body = 404, {"message": "Not Found"}
        data = json.dumps(body).encode()
        self.send_response(code)
        if code == 301:
            self.send_header("Location", "/repositories/1/releases/latest")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file + ".tmp", "w").write(str(s.server_address[1]))
os.rename(port_file + ".tmp", port_file)
s.serve_forever()
PY
python3 "$T/moved.py" "$T/port" "$kl" >/dev/null 2>&1 & spid=$!
trap 'kill "$spid" 2>/dev/null' EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
if [ -s "$T/port" ]; then
  GHAPI_T="http://127.0.0.1:$(cat "$T/port")" case_ "GitHub API 가 301(레포가 옮겨짐)" 2 "레포가 옮겨졌습니다(HTTP 301" ""
else
  bad "301 을 주는 로컬 서버가 시작되지 않았다"
fi

# ktlint 를 받는 곳: URL 의 레포가 출처 표의 레포와 같다.
repo=$(sed -n 's/^ktlint github \([^"]*\)"*$/\1/p' "$KIT/common/ci/check-tool-pins.sh")
if [ -z "$repo" ]; then
  bad "check-tool-pins.sh 의 출처 표에서 ktlint 의 레포를 읽지 못했다"
elif ! git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bad "킷이 git 체크아웃이 아니다 — 추적 파일에서 ktlint 를 받는 곳을 찾을 수 없다"
else
  # git grep 은 찾으면 0, 못 찾으면 1 이다. 그 밖은 오류이고 출력이 비므로, 출력만 보면 받는 곳이 없다고 센다.
  hits=$(git -C "$KIT" grep -n -o -E 'github\.com/[^/[:space:]]+/[^/[:space:]]+/releases/download/[^/]*/ktlint' -- . ':!docs/dev-log.md'); grc=$?
  case "$grc" in
    0|1)
      miss=""
      for f in common/ci/gates.yml common/gate/install-tools.sh common/gate/lib.sh; do
        printf '%s\n' "$hits" | grep -q "^$f:" || miss="$miss $f"
      done
      other=$(printf '%s\n' "$hits" | grep . | while IFS= read -r h; do
        r=$(printf '%s\n' "$h" | sed 's#^.*github\.com/\([^/]*/[^/]*\)/releases/download/.*$#\1#')
        [ "$r" = "$repo" ] || printf '%s\n' "$h"
      done)
      if [ -n "$miss" ]; then bad "ktlint 를 받는 URL 을 찾지 못한 파일이 있다:$miss"
      elif [ -n "$other" ]; then bad "ktlint 를 $repo 가 아닌 곳에서 받는다:"; printf '%s\n' "$other" | cut -c1-140 | sed 's/^/      /'
      else ok "ktlint 를 받는 URL 이 모두 최신을 읽는 레포($repo)를 가리킨다"; fi ;;
    *) bad "git grep 이 rc=$grc 로 실패했다 — ktlint 를 받는 곳을 알 수 없다" ;;
  esac
fi

rm -rf "$T"
exit $fail
