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
#   · detect 스텝을 돌리면 setup-go 가 설치할 Go(toolchain 줄이 있으면 그 버전, 없으면 go 줄)가 가장
#     높은 go.mod 를 gomod 로 낸다. 루트에 없어도, 문자열로는 더 높아 보이는 것(1.3)이 있어도
#     그렇다. go.mod 가 없으면 go=false 다
#   · detect 잡이 gomod 를 내보내고, setup-go 를 쓰는 잡마다 go-version-file 로 그것을 받는다.
#     캐시를 켜고, 그 키를 레포 전체의 go.mod 와 go.sum 으로 만든다(`cache-dependency-path`).
#     루트에 go.mod 가 없는 레포에서 캐시가 복원도 저장도 되지 않았다(이슈 #96)
#   · `go install` 로 도구를 설치하는 잡마다, 그 앞에서 actions/cache/restore 로 도구 디렉터리를 복원하고,
#     복원이 안 됐을 때만 그 디렉터리에 설치한 뒤 곧바로 actions/cache/save 로 저장한다. 키에는 OS · arch ·
#     setup-go 가 설치한 Go 버전 · 그 잡이 설치하는 도구의 핀이 모두 들어 있고, 잡마다 다르다. 도구를 쓰는
#     스텝보다 앞에서, 복원 여부와 상관없이 그 디렉터리를 PATH 에 더한다. setup-go 는 모듈 캐시와 빌드
#     캐시만 캐시하므로 go install 이 만든 도구는 캐시되지 않았고, setup-go 와 actions/cache 의 저장은
#     잡이 성공할 때만 실행된다(이슈 #115). 설치 스텝과 PATH 스텝은 go 대역으로 실행해 GOBIN 과 PATH 가
#     복원하는 경로와 같은지, 도구를 cgo 없이(CGO_ENABLED=0) 빌드하는지 본다. cgo 를 켜면 도구가 러너의
#     glibc 에 동적으로 링크될 수 있는데, 키에 러너 이미지가 없어 다른 이미지에서 빌드한 도구를 복원할 수 있다
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
  # setup-go 는 고른 파일에 toolchain 줄이 있으면 그 버전을 설치한다. 순위도 그 버전으로 매긴다.
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
# setup-go 스텝마다 판정한다. 주석 줄은 보지 않는다. 캐시 키는 `cache-dependency-path` 에 맞는 파일의
# 해시다. 이 입력이 없으면 setup-go 는 레포 루트의 go.mod 하나만 찾고, 없으면 경고만 내고 캐시를
# 복원도 저장도 하지 않는다(이슈 #96, probe 실행 35847040603 의 「Primary key was not generated」).
# 패턴은 `cache-dependency-path: |` 블록의 줄로만 읽는다. 스텝 글 어디에 있든 받으면 키 이름이
# 틀리거나(setup-go 는 입력이 없는 것으로 읽는다) 공백으로 이은 한 줄이어도(hashFiles 가 아무것도
# 맞히지 못한다) 통과했다(PR #114 1라운드 콜드 리뷰). 블록 안의 빈 줄은 블록의 끝이 아니다.
# cache 값은 따옴표를 쳐도, 뒤에 주석이 있어도 같다(PR #114 2라운드 콜드 리뷰).
wiring=$(awk -v q="'" '
  function blockpaths(s,   n, i, lines, ind, inb, l, t) {
    delete deps; n = split(s, lines, "\n"); inb = 0
    for (i = 1; i <= n; i++) {
      l = lines[i]
      if (l ~ /^ *cache-dependency-path: *\|[-+]? *$/) { match(l, /^ */); ind = RLENGTH; inb = 1; continue }
      if (inb) {
        if (l ~ /^ *$/) continue
        match(l, /^ */)
        if (RLENGTH > ind) { t = l; sub(/^ +/, "", t); sub(/ +$/, "", t); deps[t] = 1 }
        else inb = 0
      }
    }
  }
  function endstep() {
    if (step ~ /uses: actions\/setup-go@/) {
      n++; msg = ""; blockpaths(step)
      if (!index(step, "go-version-file: " q "${{ needs.detect.outputs.gomod }}" q)) msg = msg " detect 의 gomod 를 go-version-file 로 받지 않는다."
      if (step !~ ("cache: *[\"" q "]?true[\"" q "]? *[,}#\n]")) msg = msg " cache 가 켜져 있지 않다."
      else if (!(("**/go.mod" in deps) && ("**/go.sum" in deps)))
        msg = msg " cache-dependency-path 블록에 레포 전체의 go.mod 와 go.sum 이 다 있지 않다."
      print (msg == "" ? "ok" : "bad") "\t" job "\t" msg
    }
    step = ""
  }
  /^jobs:$/ { injobs = 1; next }
  !injobs { next }
  /^  [a-z_-]+:$/ { endstep(); job = $1; sub(/:$/, "", job); next }
  /^      - / { endstep() }
  /^[[:space:]]*#/ { next }
  { step = step $0 "\n" }
  END { endstep(); if (!n) print "none" }
' "$Y")
case "$wiring" in
  none) bad "setup-go 를 쓰는 스텝이 하나도 검색되지 않았다 — gates.yml 이 바뀌었나" ;;
  *)
    while IFS=$'\t' read -r st job msg; do
      if [ "$st" = ok ]; then ok "$job 잡의 setup-go 가 detect 의 gomod 로 Go 를 설치하고, 캐시 키를 레포 전체의 go.mod · go.sum 으로 만든다"
      else bad "$job 잡의 setup-go:$msg"; fi
    done <<< "$wiring"
    ;;
esac

# ── Go 도구 캐시 ───────────────────────────────────────────────────────
# setup-go 는 GOMODCACHE 와 GOCACHE 만 캐시하므로(setup-go v7 의 src/package-managers.ts) go install 이
# 만든 도구는 setup-go 의 캐시에 남지 않는다. 잡마다 키를 나눠도 같다. 그래서 도구 디렉터리를
# actions/cache 로 따로 캐시한다.
# 저장을 설치 바로 뒤에 두는 이유: setup-go 와 actions/cache 의 post 는 `post-if: success()` 라서 뒤의
# 게이트가 실패한 실행에서는 저장하지 않는다.
python3 -c 'import yaml' 2>/dev/null || bad "python3 의 yaml 모듈이 없다 — Go 도구 캐시를 볼 수 없다"
mkdir -p "$T/gobin"
cat > "$T/gobin/go" <<'EOF'
#!/usr/bin/env bash
# go 대역. 설치 스텝의 `go install` 은 그때의 GOBIN 과 CGO_ENABLED 를 적고, `go env GOPATH` 에는 답한다.
case "$1" in
  install) printf '%s\t%s\t%s\n' "${GOBIN-}" "${CGO_ENABLED-(없음)}" "$*" >> "$GO_LOG" ;;
  env) [ "${2-}" = GOPATH ] && echo "$HOME/go" ;;
  *) echo "go 대역: 모르는 호출: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/gobin/go"
cat > "$T/gotools.py" <<'PY'
import os, re, subprocess, sys, yaml

Y, T, TV = sys.argv[1:4]
wf = yaml.safe_load(open(Y, encoding="utf-8"))
pins = {}
for l in open(TV, encoding="utf-8").read().splitlines():
    if l and not l.startswith("#") and "=" in l:
        k, v = l.split("=", 1); pins[k] = v
GI = re.compile(r"go install (?:-\S+ )*(\S+?)@\$\{\{ steps\.tv\.outputs\.([a-z_]+) \}\}")
fails = 0
def ok(m): print("  ✓ " + m)
def bad(m):
    global fails; fails += 1; print("  ✗ " + m)
def has(text, name):
    return re.search(r"\$\{\{\s*" + re.escape(name) + r"\s*\}\}", str(text or "")) is not None
def miss_only(step, rid):
    return re.search(r"steps\." + re.escape(rid) + r"\.outputs\.cache-hit\s*!=\s*'true'", str(step.get("if") or "")) is not None
def uses(step, action):
    return str(step.get("uses") or "").startswith(action + "@")

# 스텝의 run 을 러너처럼 `bash -e` 로 실행한다. 핀은 tool-versions 의 값으로, 다른 식은 X 로 바꾼다.
def run_step(step, name):
    home = os.path.join(T, "home-" + name); os.makedirs(home, exist_ok=True)
    gp, gl = os.path.join(T, "ghpath-" + name), os.path.join(T, "golog-" + name)
    for f in (gp, gl): open(f, "w").close()
    body = re.sub(r"\$\{\{ steps\.tv\.outputs\.([a-z_]+) \}\}", lambda m: pins.get(m.group(1), "X"), step.get("run") or "")
    body = re.sub(r"\$\{\{[^}]*\}\}", "X", body)
    env = dict(os.environ, HOME=home, GITHUB_PATH=gp, GO_LOG=gl, PATH=os.path.join(T, "gobin") + ":" + os.environ["PATH"])
    for k in ("GOBIN", "CGO_ENABLED"):     # 테스트를 실행하는 환경의 값이 스텝의 값처럼 보이지 않게 한다
        env.pop(k, None)
    p = subprocess.run(["bash", "-e", "-c", body], env=env, cwd=T, capture_output=True, text=True)
    return p.returncode, home, open(gp).read().splitlines(), [l.split("\t", 2) for l in open(gl).read().splitlines()], p.stderr

keys = {}
for job, spec in (wf.get("jobs") or {}).items():
    steps = spec.get("steps") or []
    inst = [i for i, s in enumerate(steps) if "go install" in (s.get("run") or "")]
    if not inst:
        continue
    tools = [m for i in inst for m in GI.findall(steps[i]["run"])]
    rest = [i for i in range(inst[0]) if uses(steps[i], "actions/cache/restore")]
    if not rest:
        bad(f"{job} 잡: go install 앞에 actions/cache/restore 가 없다 — 도구를 실행마다 다시 빌드한다")
        continue
    ri = rest[-1]; r = steps[ri]; rid = r.get("id"); w = r.get("with") or {}
    path, key = str(w.get("path") or "").strip(), str(w.get("key") or "")
    msg = []
    if not rid: msg.append("restore 스텝에 id 가 없다.")
    if not path or "\n" in path: msg.append(f"restore 의 path 가 디렉터리 하나가 아니다({path!r}).")
    if "restore-keys" in w: msg.append("restore-keys 가 있다 — 다른 버전으로 빌드한 도구를 복원할 수 있다.")
    gos = [s for s in steps[:ri] if uses(s, "actions/setup-go")]
    if not gos or not gos[-1].get("id"): msg.append("restore 앞의 setup-go 에 id 가 없다 — 키가 Go 버전을 읽을 수 없다.")
    elif not has(key, f"steps.{gos[-1]['id']}.outputs.go-version"): msg.append("키에 setup-go 가 설치한 Go 버전이 없다.")
    for ctx in ("runner.os", "runner.arch"):
        if not has(key, ctx): msg.append(f"키에 {ctx} 가 없다.")
    for pkg, k in tools:
        if not has(key, f"steps.tv.outputs.{k}"): msg.append(f"키에 {k} 의 핀이 없다.")
    if not tools: msg.append("go install 줄에서 도구와 핀을 읽지 못했다.")
    home_path = lambda home: re.sub(r"^(~|\$HOME|\$\{HOME\})(?=/|$)", home, path)
    for i in inst:
        s = steps[i]
        if rid and not miss_only(s, rid): msg.append(f"설치 스텝 {i + 1} 이 복원이 안 됐을 때만 실행되지 않는다.")
        rc, home, _, calls, err = run_step(s, f"{job}-{i}")
        if rc != 0: msg.append(f"설치 스텝 {i + 1} 이 go 대역으로 실패했다: {err.strip()[:120]}")
        for gobin, cgo, args in calls:
            if gobin != home_path(home): msg.append(f"`go {args}` 의 GOBIN 이 {gobin or '(없음)'}, 복원하는 {home_path(home)} 여야 한다.")
            if cgo != "0": msg.append(f"`go {args}` 의 CGO_ENABLED 가 {cgo}, 0 이어야 한다 — 도구가 러너의 glibc 에 동적으로 링크될 수 있다.")
    names = {pkg.rsplit("/", 1)[-1] for pkg, _ in tools}
    after = range(inst[-1] + 1, len(steps))
    use = next((i for i in after if "gate.sh" in (steps[i].get("run") or "") or any(n in (steps[i].get("run") or "") for n in names)), None)
    if use is None: msg.append("설치한 도구를 쓰는 스텝(gate.sh 나 도구 이름)이 없다.")
    saves = [i for i in after if uses(steps[i], "actions/cache/save")]
    if not saves: msg.append("설치 뒤에 actions/cache/save 가 없다.")
    else:
        si = saves[0]; s = steps[si]; sw = s.get("with") or {}
        if use is not None and si > use: msg.append("save 가 도구를 쓰는 스텝보다 뒤에 있다 — 게이트가 실패하면 저장되지 않는다.")
        if rid and not miss_only(s, rid): msg.append("save 가 복원이 안 됐을 때만 실행되지 않는다.")
        if str(sw.get("path") or "").strip() != path: msg.append("save 의 path 가 restore 와 다르다.")
        if rid and not has(sw.get("key"), f"steps.{rid}.outputs.cache-primary-key"): msg.append("save 의 key 가 restore 의 cache-primary-key 가 아니다.")
    added = False
    for i in range(ri + 1, use if use is not None else len(steps)):
        s = steps[i]
        if "GITHUB_PATH" not in (s.get("run") or "") or "cache-hit" in str(s.get("if") or ""):
            continue
        rc, home, lines, _, _ = run_step(s, f"{job}-path-{i}")
        if rc == 0 and home_path(home) in lines:
            added = True
    if not added: msg.append("도구를 쓰는 스텝 앞에서, 복원 여부와 상관없이 도구 디렉터리를 PATH 에 더하는 스텝이 없다.")
    keys[job] = key
    if msg: bad(f"{job} 잡의 Go 도구 캐시: " + " ".join(msg))
    else: ok(f"{job} 잡은 Go 도구({', '.join(sorted(names))})를 따로 캐시하고, 복원이 안 됐을 때만 cgo 없이 빌드해 곧바로 저장한다")
if not keys and not fails:
    bad("go install 로 도구를 설치하는 잡이 하나도 검색되지 않았다 — gates.yml 이 바뀌었나")
if len(set(keys.values())) < len(keys):
    bad("두 잡 이상이 같은 도구 캐시 키를 쓴다 — 먼저 끝난 잡의 도구만 저장된다")
elif len(keys) > 1:
    ok("도구 캐시 키가 잡마다 다르다")
sys.exit(1 if fails else 0)
PY
python3 "$T/gotools.py" "$Y" "$T" "$R/.ai-kit/gate/tool-versions" || fail=1

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
