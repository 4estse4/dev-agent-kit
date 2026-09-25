#!/usr/bin/env bash
# CI 의 setup-java 가 gradle 캐시 키를 빌드 루트가 어디에 있든 그 빌드 루트의 의존성 파일로 만든다.
#
# 이 테스트가 있는 이유: setup-java 는 `cache: gradle` 만 주면 기본 패턴으로 키를 만드는데, 그 가운데
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

rm -rf "$T"
exit $fail
