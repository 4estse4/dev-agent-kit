#!/usr/bin/env bash
# CI 는 레포에 있는 go.mod 로 Go 를 설치하고, 모듈마다 커버리지를 측정하고, 실패를 삼키지 않는다.
#
# 이 테스트가 있는 이유: gates.yml 이 go.mod 가 레포 루트에 있다고 가정했다(이슈 #93).
# go.mod 가 backend/ 에만 있는 레포에서 setup-go 를 쓰는 세 잡이 모두
# 「The specified go version file at: go.mod does not exist」로 죽었고, coverage 잡은
# `go test | tee` 에 pipefail 이 없어 테스트가 실패해도 초록이었다. 둘 다 러너에서 돌려 봐야
# 드러났고, 이 레포의 검사는 그 자리를 하나도 보지 않았다.
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 을 읽는다. 보는 것:
#   · detect 스텝을 돌리면 setup-go 가 깔 Go(toolchain 줄이 있으면 그 버전, 없으면 go 줄)가 가장
#     높은 go.mod 를 gomod 로 낸다. 루트에 없어도, 문자열로는 더 높아 보이는 것(1.3)이 있어도
#     그렇다. go.mod 가 없으면 go=false 다
#   · detect 잡이 gomod 를 내보내고, setup-go 를 쓰는 잡마다 go-version-file 로 그것을 받는다
#   · coverage 스텝을 go 대역으로 돌리면 모듈마다 그 디렉터리에서 go test 를 부르고, 한 모듈이
#     실패하면 이유를 말하며 실패하고, COVER_MIN 을 넘는지 판정한다. 숫자로 된 커버리지 줄이
#     하나도 없을 때 말없이 실패하지 않는다
# 스텝은 러너의 기본 셸처럼 `bash -e` 로 돈다. coverage 스텝이 쓰는 /tmp/cov.txt 는 테스트
# 디렉터리로 바꿔 돌린다.
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

ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# $1=잡  $2=스텝 머리에 든 글자(`id: d` 같은). 그 스텝의 `run: |` 본문을 낸다.
step_run() {
  awk -v want="$1" -v pat="$2" '
    function flush() { if (inj && hit && !done) { printf "%s", body; done = 1 } body = ""; hit = 0; inrun = 0 }
    /^jobs:$/ { injobs = 1; next }
    !injobs { next }
    /^  [a-z_-]+:$/ { flush(); j = $1; sub(/:$/, "", j); inj = (j == want); next }
    /^      - / { flush() }
    !inj { next }
    inrun && /^          / { l = $0; sub(/^          /, "", l); body = body l "\n"; next }
    inrun { inrun = 0 }
    index($0, pat) { hit = 1 }
    /^ +(- )?run: *\|$/ { inrun = 1 }
    END { flush() }
  ' "$Y"
}

gomods() { # 인자=「경로:go 줄[:toolchain 줄]」. 경로가 . 이면 루트에 둔다
  local a p v tc
  rm -rf "$R/go.mod" "$R/backend" "$R/tools"
  for a in "$@"; do
    p="${a%%:*}"; v="${a#*:}"; tc=""
    case "$v" in *:*) tc="${v#*:}"; v="${v%%:*}" ;; esac
    mkdir -p "$R/$p"
    { printf 'module example.com/m\n\ngo %s\n' "$v"; [ -z "$tc" ] || printf '\ntoolchain %s\n' "$tc"; } > "$R/$p/go.mod"
  done
}

# ── detect ─────────────────────────────────────────────────────────────
step_run detect 'id: d' > "$T/detect.sh"
if ! grep -q 'go=' "$T/detect.sh"; then
  bad "detect 잡에서 id: d 스텝을 못 뽑았다 — gates.yml 이 바뀌었나"
else
  detect() { # $1=설명  $2=기대하는 gomod(없으면 go=false)  나머지=gomods 인자
    local what="$1" want="$2" got go; shift 2
    gomods "$@"
    mkdir -p "$T/rt"; : > "$T/out"
    (cd "$R" && RUNNER_TEMP="$T/rt" GITHUB_OUTPUT="$T/out" bash -e "$T/detect.sh") > "$T/detect.log" 2>&1 \
      || { bad "detect · $what → 스텝이 실패했다:"; sed 's/^/      /' "$T/detect.log"; return; }
    got=$(sed -n 's/^gomod=//p' "$T/out"); go=$(sed -n 's/^go=//p' "$T/out")
    if [ -z "$want" ]; then
      if [ "$go" = false ] && [ -z "$got" ]; then ok "detect · $what → go=false"
      else bad "detect · $what → go=$go gomod=$got, go=false 여야 한다"; fi
    elif [ "$go" = true ] && [ "$got" = "$want" ]; then ok "detect · $what → gomod=$got"
    else bad "detect · $what → go=$go gomod=$got, gomod=$want 여야 한다"; fi
  }
  detect "backend 1.25 · tools/x 1.26"  tools/x/go.mod  backend:1.25 tools/x:1.26
  detect "루트 1.25 · backend 1.26"     backend/go.mod  .:1.25 backend:1.26
  detect "루트 1.26 · backend 1.25"     go.mod          .:1.26 backend:1.25
  detect "backend 1.26.1 · tools/x 1.3" backend/go.mod  backend:1.26.1 tools/x:1.3
  # setup-go 는 고른 파일에 toolchain 줄이 있으면 그 버전을 깐다. 순위도 그 버전으로 매긴다.
  # go 줄을 올리는 go 명령이 toolchain 줄을 같이 쓰므로(go.dev/doc/toolchain) 루트에만 그 줄이
  # 있고 하위 모듈의 go 줄이 같은 배치가 흔하다(이슈 #99).
  detect "루트 1.25.0+toolchain go1.26.2 · tools/x 1.25.0" go.mod         .:1.25.0:go1.26.2 tools/x:1.25.0
  detect "루트 1.24.0+toolchain go1.26.1 · tools/x 1.25.0" go.mod         .:1.24.0:go1.26.1 tools/x:1.25.0
  # toolchain 을 읽되 go 접두사를 안 떼면 go1.25.4 가 문자열로 1.26.0 을 앞선다.
  detect "backend 1.25.0+toolchain go1.25.4 · tools/x 1.26.0" tools/x/go.mod backend:1.25.0:go1.25.4 tools/x:1.26.0
  detect "go.mod 없음"                  ""
fi

# ── 배선 ───────────────────────────────────────────────────────────────
grep -qE '^      gomod: \$\{\{ steps\.d\.outputs\.gomod \}\}$' "$Y" \
  && ok "detect 잡이 gomod 를 내보낸다" || bad "detect 잡의 outputs 에 gomod 가 없다"
wiring=$(awk '
  /^jobs:$/ { injobs = 1; next }
  !injobs || /^[[:space:]]*#/ { next }
  /^  [a-z_-]+:$/ { job = $1; sub(/:$/, "", job); next }
  /uses: actions\/setup-go@/ { n++; pend = 1; next }
  pend { print (index($0, "go-version-file: '\''${{ needs.detect.outputs.gomod }}'\''") ? "ok " : "bad ") job; pend = 0 }
  END { if (!n) print "none" }
' "$Y")
case "$wiring" in
  none) bad "setup-go 를 쓰는 잡이 하나도 안 걸렸다 — gates.yml 이 바뀌었나" ;;
  *)
    while read -r st job; do
      if [ "$st" = ok ]; then ok "$job 잡의 setup-go 가 detect 의 gomod 로 Go 를 깐다"
      else bad "$job 잡의 setup-go 가 detect 의 gomod 를 받지 않는다"; fi
    done <<< "$wiring"
    ;;
esac

# ── coverage ───────────────────────────────────────────────────────────
step_run coverage '패키지별 커버리지' | sed "s#/tmp/cov.txt#$T/cov.txt#g" > "$T/coverage.sh"
mkdir -p "$T/bin"
cat > "$T/bin/go" <<'EOF'
#!/usr/bin/env bash
# go 대역. coverage 스텝이 부르는 `go test -cover ./...` 만 흉내 낸다. 모듈 디렉터리에서만 불려야 한다.
[ "$*" = "test -cover ./..." ] || { echo "go 대역: 모르는 호출: $*"; exit 2; }
[ -f go.mod ] || { echo "go 대역: 모듈 밖에서 불렸다: $PWD"; exit 2; }
echo "${PWD##*/}" >> "$GO_CALLS"
if [ -f FAIL ]; then printf -- '--- FAIL: TestX (0.00s)\nFAIL\texample.com/m\t0.001s\n'; exit 1; fi
if [ -f NOSTMT ]; then printf 'ok  \texample.com/m\t0.001s\tcoverage: [no statements]\n'; exit 0; fi
printf 'ok  \texample.com/m\t0.001s\tcoverage: %s%% of statements\n' "$(cat COVER 2>/dev/null || echo 80.0)"
EOF
chmod +x "$T/bin/go"
if ! grep -q 'go test' "$T/coverage.sh"; then
  bad "coverage 잡에서 커버리지 스텝을 못 뽑았다 — gates.yml 이 바뀌었나"
else
  # 모듈은 backend(1.25) 와 tools/x(1.26) 둘이다. go 대역이 불린 디렉터리를 GO_CALLS 에 적으므로,
  # find 가 어느 순서로 내든 두 모듈에서 한 번씩 불렸는지를 본다.
  cover() { # $1=설명  $2=COVER_MIN  $3=기대(pass|fail)  $4=출력에 있어야 할 글자(비면 안 봄)  나머지=「모듈:표시 파일」
    local what="$1" min="$2" want="$3" must="$4" a out rc calls; shift 4
    gomods backend:1.25 tools/x:1.26
    for a in "$@"; do [ -z "${a#*:}" ] || : > "$R/${a%%:*}/${a#*:}"; done
    : > "$T/calls"
    out=$(cd "$R" && PATH="$T/bin:$PATH" GO_CALLS="$T/calls" COVER_MIN="$min" GITHUB_STEP_SUMMARY="$T/summary" bash -e "$T/coverage.sh" 2>&1); rc=$?
    calls=$(sort "$T/calls" | tr '\n' ' ')
    if ! { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } && ! { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
      bad "coverage · $what → rc=$rc, $want 여야 한다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'
    elif [ "$calls" != "backend x " ]; then
      bad "coverage · $what → go test 를 부른 디렉터리가 「${calls}」, 두 모듈에서 한 번씩이어야 한다"
    elif [ -n "$must" ] && ! printf '%s\n' "$out" | grep -qF -- "$must"; then
      bad "coverage · $what → rc=$rc 인데 「${must}」 이 출력에 없다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'
    else
      ok "coverage · $what → rc=$rc, 두 모듈에서 go test"
    fi
  }
  cover "두 모듈 통과"                      ""  pass ""                                        backend: tools/x:
  cover "backend 테스트 실패"               ""  fail "::error::go test 가 실패한 모듈이 있습니다" backend:FAIL tools/x:
  cover "COVER_MIN=90 · 80%"               90  fail "::error::COVER_MIN=90 미만"             backend: tools/x:
  cover "COVER_MIN=50 · 문장 없는 패키지뿐" 50  pass ""                                        backend:NOSTMT tools/x:NOSTMT
fi

rm -rf "$T"
exit $fail
