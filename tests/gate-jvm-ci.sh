#!/usr/bin/env bash
# 킷의 JVM 은 Kotlin 과 Gradle 이다. `pom.xml` 만 있는 디렉터리는 JVM 빌드 루트가 아니고, 킷 파일에 Maven 의
# 흔적이 없다. CI 의 setup-java 는 gradle 캐시 키를 빌드 루트가 어디에 있든 그 빌드 루트의 의존성 파일로 만든다.
#
# 이 테스트가 있는 이유 (1): 킷은 Maven 을 지원하는 코드와 문장을 두었지만 CI 는 늘 `cache: gradle` 이라,
# `pom.xml` 만 있는 레포에서 setup-java 가 맞는 파일을 못 찾아 실패했다(이슈 #127, setup-java v6 의
# src/cache.ts 의 computeCacheKey). 사람이 Maven 을 아예 배제하기로 정했고, 그래서 흔적까지 걷어냈다.
# 다음을 본다. `pom.xml` 을 만들어 보는 검사라 흔적 검사는 이 파일을 뺀다:
#   · 흔적: 추적 파일 전부에서 Maven 을 가리키는 글자가 0 건이다. `docs/dev-log.md` 는 그때의 기록이라 뺀다
#   · detect 스텝을 실행하면 `pom.xml` 만 있는 레포(루트 · backend/)는 jvm=false, gradle 마커가 있으면 jvm=true
#   · 래퍼 검사 스텝은 `pom.xml` 옆에 래퍼를 요구하지 않고, gradle 빌드 루트에 `gradlew` 가 없으면 실패한다
#   · `pom.xml` 만 있는 레포에서 `gate.sh --all` 이 검사 대상 없음으로 끝난다
#   · `install.sh` 가 `pom.xml` 옆에 `.editorconfig` 를 놓지 않는다
#
# 이 테스트가 있는 이유 (2): setup-java 는 `cache: gradle` 만 주면 기본 패턴으로 키를 만드는데, 그 가운데
# `gradle/*.versions.toml` · `buildSrc/**/Versions.kt` · `buildSrc/**/Dependencies.kt` 는 레포 루트에 묶여
# 있다. 킷은 하위 디렉터리의 빌드 루트를 지원하므로(gates.yml 의 빌드 루트별 래퍼 검사) 빌드 루트가
# backend/ 이면 버전 카탈로그가 키에 들어가지 않고, 카탈로그에서만 버전을 올려도 전의 캐시를 복원하고
# 저장하지 않는다(이슈 #116).
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 의 setup-java 스텝마다 본다:
#   · gradle 캐시를 켠다
#   · setup-java 가 실제로 쓰는 패턴(`cache-dependency-path` 가 있으면 그것, 없으면 기본 패턴)이, 빌드 루트가
#     레포 루트일 때와 backend/ 일 때 모두 기본 패턴이 레포 루트에서 맞히는 파일을 다 맞힌다. 소스 파일은
#     맞히지 않는다 — 맞히면 소스를 고칠 때마다 키가 바뀌어 캐시를 다시 받는다
# setup-java 는 `cache-dependency-path` 를 주면 기본 패턴 대신 그것만 쓴다(setup-java v6 의 src/cache.ts 의
# computeCacheKey). 패턴은 python 의 glob(recursive)으로 맞힌다. setup-java 가 쓰는 @actions/glob 과 다른
# 점이 둘 있다. @actions/glob 은 점으로 시작하는 이름에도 맞고, 디렉터리에 맞으면 그 아래 파일도 해시한다.
# python 의 glob 은 둘 다 하지 않는다. 이 테스트의 파일에는 점으로 시작하는 이름이 없고 gradle 패턴은 파일
# 이름으로 맞히므로, 이 파일 구성에서는 두 쪽 결과가 같다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
python3 -c 'import yaml' 2>/dev/null || { bad "python3 의 yaml 모듈이 없다 — gates.yml 을 읽을 수 없다"; exit 1; }

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
Y="$R/.github/workflows/gates.yml"
[ -f "$Y" ] || { echo "  ✗ $Y 가 없다 — 설치 경로가 바뀌었나"; exit 1; }

cat > "$T/java.py" <<'PY'
import glob, os, sys, yaml

Y, T = sys.argv[1:3]
# setup-java v6(de7274f)의 src/cache.ts 에 있는 gradle 기본 패턴.
DEFAULT = ["**/*.gradle*", "**/gradle.properties", "**/gradle-wrapper.properties",
           "buildSrc/**/Versions.kt", "buildSrc/**/Dependencies.kt", "gradle/*.versions.toml",
           "**/versions.properties"]
# 빌드 루트 하나의 파일. 앞의 것은 기본 패턴이 레포 루트에서 맞히는 파일이고, SRC 는 소스다.
DEPS = ["build.gradle.kts", "settings.gradle.kts", "gradle.properties", "versions.properties",
        "gradle/wrapper/gradle-wrapper.properties", "gradle/libs.versions.toml",
        "buildSrc/src/main/kotlin/Versions.kt", "buildSrc/src/main/kotlin/Dependencies.kt"]
SRC = ["src/main/kotlin/App.kt", "buildSrc/src/main/kotlin/Conventions.kt"]

def layout(name, root):
    d = os.path.join(T, name)
    for f in DEPS + SRC:
        p = os.path.join(d, root, f); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, "w").close()
    return d

def matched(d, patterns):
    return {os.path.relpath(p, d) for pat in patterns for p in glob.glob(os.path.join(d, pat), recursive=True) if os.path.isfile(p)}

want = matched(layout("rootcheck", ""), DEFAULT)
assert want == set(DEPS), sorted(want)   # 기본 패턴이 레포 루트에서 DEPS 를 다 맞힌다는 전제
fails = n = 0
wf = yaml.safe_load(open(Y, encoding="utf-8"))
for job, spec in (wf.get("jobs") or {}).items():
    for s in spec.get("steps") or []:
        if not str(s.get("uses") or "").startswith("actions/setup-java@"):
            continue
        n += 1; w = s.get("with") or {}; msg = []
        if str(w.get("cache") or "") != "gradle":
            msg.append(f"gradle 캐시를 켜지 않는다(cache={w.get('cache')!r}).")
        given = w.get("cache-dependency-path")
        pats = [l.strip() for l in str(given).splitlines() if l.strip()] if given else DEFAULT
        for name, root in (("루트", ""), ("backend/", "backend")):
            got = matched(layout(f"{job}-{n}-{name.strip('/')}", root), pats)
            lack = sorted(f for f in DEPS if os.path.join(root, f) not in got)
            extra = sorted(f for f in SRC if os.path.join(root, f) in got)
            if lack: msg.append(f"빌드 루트가 {name} 일 때 키에 들지 않는다: {', '.join(lack)}.")
            if extra: msg.append(f"빌드 루트가 {name} 일 때 소스가 키에 든다: {', '.join(extra)}.")
        if msg:
            fails += 1; print(f"  ✗ {job} 잡의 setup-java: " + " ".join(msg))
        else:
            print(f"  ✓ {job} 잡의 setup-java 는 빌드 루트가 루트든 backend/ 든 그 빌드 루트의 의존성 파일로 gradle 캐시 키를 만든다")
if not n:
    fails += 1; print("  ✗ setup-java 를 쓰는 스텝이 하나도 검색되지 않았다 — gates.yml 이 바뀌었나")
sys.exit(1 if fails else 0)
PY
python3 "$T/java.py" "$Y" "$T" || fail=1

# ── Maven 을 지원하지 않는다 ───────────────────────────────────────────
# 흔적: 추적 파일 전부. 이 파일은 아래에서 `pom.xml` 을 만들어 보므로 뺀다.
if ! git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bad "킷이 git 체크아웃이 아니다 — 추적 파일에서 Maven 의 흔적을 찾을 수 없다"
else
  hits=$(git -C "$KIT" grep -n -i -e 'maven' -e 'mvn' -e 'pom\.xml' -e 'wrapper:wrapper' -- . ':!docs/dev-log.md' ':!tests/gate-jvm-ci.sh')
  if [ -z "$hits" ]; then ok "킷 파일에 Maven 의 흔적이 없다(docs/dev-log.md 와 이 테스트는 빼고)"
  else bad "킷 파일에 Maven 의 흔적이 있다:"; printf '%s\n' "$hits" | cut -c1-140 | sed 's/^/      /'; fi
fi

# gates.yml 의 한 스텝의 run 을 낸다. $1=잡  $2=id 또는 name
step_body() {
  python3 - "$Y" "$1" "$2" <<'PY'
import sys, yaml
y, job, want = sys.argv[1:4]
for s in yaml.safe_load(open(y, encoding="utf-8"))["jobs"][job]["steps"]:
    if want in (s.get("id"), s.get("name")):
        print(s.get("run") or ""); break
PY
}
step_body detect d > "$T/detect.sh"
step_body gate 'require an executable wrapper at every build root' > "$T/wrapper.sh"
grep -q 'jvm=' "$T/detect.sh" || bad "detect 잡에서 id: d 스텝을 못 뽑았다 — gates.yml 이 바뀌었나"
grep -q 'gradlew' "$T/wrapper.sh" || bad "gate 잡에서 래퍼 검사 스텝을 못 뽑았다 — gates.yml 이 바뀌었나"

# $R 의 빌드 파일을 지우고 인자대로 놓는다. 인자=「경로」(gradlew 는 실행권한을 준다)
layout() {
  local p
  rm -rf "$R/pom.xml" "$R/backend" "$R/kt"
  for p in "$@"; do
    mkdir -p "$(dirname "$R/$p")"; : > "$R/$p"
    case "$p" in */gradlew|gradlew) chmod +x "$R/$p" ;; esac
  done
}
detect() { # $1=설명  $2=기대하는 jvm 값  나머지=layout 인자
  local what="$1" want="$2" got; shift 2
  layout "$@"; mkdir -p "$T/rt"; : > "$T/out"
  (cd "$R" && RUNNER_TEMP="$T/rt" GITHUB_OUTPUT="$T/out" bash -e "$T/detect.sh") > "$T/detect.log" 2>&1 \
    || { bad "detect · $what → 스텝이 실패했다:"; sed 's/^/      /' "$T/detect.log"; return; }
  got=$(sed -n 's/^jvm=//p' "$T/out")
  [ "$got" = "$want" ] && ok "detect · $what → jvm=$got" || bad "detect · $what → jvm=$got, jvm=$want 여야 한다"
}
detect "루트에 pom.xml 만"           false pom.xml
detect "backend/ 에 pom.xml 만"      false backend/pom.xml
detect "kt/ 에 settings.gradle.kts"  true  kt/settings.gradle.kts kt/gradlew

wrapper() { # $1=설명  $2=기대(pass|fail)  나머지=layout 인자
  local what="$1" want="$2" rc; shift 2
  layout "$@"
  (cd "$R" && bash -e "$T/wrapper.sh") > "$T/wrapper.log" 2>&1; rc=$?
  if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then ok "래퍼 검사 · $what → rc=$rc"
  else bad "래퍼 검사 · $what → rc=$rc, $want 여야 한다:"; sed 's/^/      /' "$T/wrapper.log" | head -5; fi
}
wrapper "backend/pom.xml(래퍼 없음) · kt/(gradlew 있음)" pass backend/pom.xml kt/settings.gradle.kts kt/gradlew
wrapper "kt/ 에 gradlew 없음"                            fail kt/settings.gradle.kts

# 게이트: pom.xml 만 있으면 검사할 모듈이 없다.
layout pom.xml
out=$(cd "$R" && bash .ai-kit/gate/gate.sh --all 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '검사 대상 없음'; then ok "gate.sh --all · 루트에 pom.xml 만 → 검사 대상 없음"
else bad "gate.sh --all · 루트에 pom.xml 만 → rc=$rc, 검사 대상 없음이어야 한다:"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /'; fi

# 설치: pom.xml 옆에 .editorconfig 를 놓지 않는다.
R2="$T/repo2"; mkdir -p "$R2/backend"
git init -q -b main "$R2"
git -C "$R2" config user.email t@example.com; git -C "$R2" config user.name T
: > "$R2/backend/pom.xml"; git -C "$R2" add -A; git -C "$R2" commit -q -m init
if ! bash "$KIT/install.sh" "$R2" > "$T/install2.log" 2>&1; then bad "backend/pom.xml 만 있는 레포에 설치가 실패했다:"; tail -3 "$T/install2.log" | sed 's/^/      /'
elif [ -e "$R2/backend/.editorconfig" ]; then bad "install.sh 가 backend/pom.xml 옆에 .editorconfig 를 놓았다"
else ok "install.sh 는 backend/pom.xml 옆에 .editorconfig 를 놓지 않는다"; fi

rm -rf "$T"
exit $fail
