#!/usr/bin/env bash
# 설치되는 .github/dependabot.yml 이 github-actions 만 켜고, 언어별 생태계는 주석으로 두는가(이슈 #39).
#
# 이 테스트가 있는 이유: 템플릿이 gomod · npm 을 켜 두어 `--lang` 과 상관없이 그대로 설치됐다. 매니페스트가
# 없는 생태계는 Dependabot 이 매주 실패시킨다. `--lang py,ts` 로 설치한 프로젝트에서 go_modules ·
# npm_and_yarn 업데이터가 설치 직후부터 실패했다. 매니저와 매니페스트가 있는 디렉터리는 설치 시점에 킷이
# 알 수 없으므로, 언어별 항목은 주석으로 두고 매니페스트를 만든 사람이 채워 켠다.
#
# `install.sh <레포> --ci [--lang …]` 으로 설치한 파일을 본다:
#   · 여러 --lang 조합과 --lang 없는 설치에서, YAML 로 읽은 updates 의 생태계가 github-actions 하나다
#   · 킷의 어댑터 언어(install.sh 의 ALL_LANGS)마다 주석 블록이 있고, 그 주석을 풀면 YAML 로 읽히며 그
#     생태계가 updates 에 들어간다. 주석을 푸는 사람이 받는 것이 그대로 쓸 수 있는 설정이어야 한다
#   · 블록에 붙은 설명 줄까지 2칸 주석을 모두 풀어도 파일이 읽힌다
#   · 두 경우 모두 항목마다 Dependabot 의 필수 키(directory 또는 directories · schedule.interval)가 있다
#
# 주석 블록은 `  # - package-ecosystem: …` 와 그 아래 `  #   <키>: …` 줄이다. 앞의 `  # ` 를 `  ` 로 바꾸면
# 풀린다. 블록 사이의 설명 주석은 이 모양이 아니어서 그대로 남는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
python3 -c 'import yaml' 2>/dev/null || { bad "python3 의 yaml 모듈이 없다 — 설치본을 YAML 로 읽을 수 없다"; exit 1; }

cat > "$T/check.py" <<'PY'
import re, sys, yaml

path, mode = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

# 문서의 필수 키(dependabot-options-reference 의 Required keys): version · updates, 그리고 항목마다
# package-ecosystem · directory 또는 directories · schedule.interval
def ecosystems(t):
    d = yaml.safe_load(t) or {}
    if d.get("version") != 2:
        raise ValueError("version 이 2 가 아니다")
    out = []
    for u in d.get("updates") or []:
        name = u.get("package-ecosystem")
        if not (u.get("directory") or u.get("directories")):
            raise ValueError(f"{name}: directory · directories 가 없다")
        if not (u.get("schedule") or {}).get("interval"):
            raise ValueError(f"{name}: schedule.interval 이 없다")
        out.append(name)
    return out

if mode == "enabled":
    try:
        e = ecosystems(text)
    except Exception as x:
        print(str(x).splitlines()[0])
        sys.exit(1)
    print(f"켜진 생태계 {e}")
    sys.exit(0 if e == ["github-actions"] else 1)

# mode == "examples": 주석 블록을 풀고 읽는다
opened = re.sub(r"(?m)^  # (?=- |  )", "  ", text)
try:
    e = ecosystems(opened)
except Exception as x:
    print("주석을 푼 파일이 Dependabot 설정으로 읽히지 않는다: " + str(x).splitlines()[0])
    sys.exit(1)
want = {"go": ["gomod"], "ts": ["npm"], "py": ["uv", "pip"], "jvm": ["gradle", "maven"]}
bad = 0
# 어댑터 언어는 install.sh 의 ALL_LANGS 에서 받는다. 언어를 더하면서 이 파일을 잊으면 여기서 실패한다.
for lang in sys.argv[3].split():
    if lang not in want:
        print(f"{lang}: 어댑터 언어인데 이 테스트의 생태계 목록(want)에 없다 — dependabot.yml 에 블록을 더하고 want 에도 더한다")
        bad = 1
for lang, names in want.items():
    missing = [n for n in names if n not in e]
    if missing:
        print(f"{lang}: 주석 블록이 없다 — {', '.join(missing)}")
        bad = 1
# 2칸 들여쓴 주석을 모두 풀어도 읽혀야 한다. 에디터로 블록을 고를 때 블록에 붙은 설명 줄까지 함께 풀리기
# 쉽다. 그 줄이 따로 서 있으면 updates 안에 YAML 이 아닌 줄이 남아 파일 전체가 읽히지 않는다.
try:
    ecosystems(re.sub(r"(?m)^  # ", "  ", text))
except Exception as x:
    print("2칸 주석을 모두 푼 파일이 Dependabot 설정으로 읽히지 않는다: " + str(x).splitlines()[0])
    bad = 1
print(f"주석을 푼 생태계 {e}")
sys.exit(bad)
PY

# $1=사본 이름  나머지=install.sh 에 더 줄 인자. 설치된 dependabot.yml 경로를 출력한다. 설치가 실패하면 빈 줄.
install_ci() {
  local R="$T/repo-$1"; shift
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  git -C "$R" commit -q --allow-empty -m init
  bash "$KIT/install.sh" "$R" --ci "$@" > "$R.log" 2>&1 || { echo ""; return 1; }
  echo "$R/.github/dependabot.yml"
}

for keep in "" go ts py jvm py,ts go,jvm,py,ts; do
  if [ -z "$keep" ]; then name=all; y=$(install_ci all); label="--lang 없음"
  else name=${keep//,/-}; y=$(install_ci "$name" --lang "$keep"); label="--lang $keep"; fi
  if [ -z "$y" ] || [ ! -f "$y" ]; then bad "$label: 설치가 실패했거나 .github/dependabot.yml 이 없다"; continue; fi
  out=$(python3 "$T/check.py" "$y" enabled 2>&1)
  if [ $? -eq 0 ]; then ok "$label: 켜진 생태계는 github-actions 하나다"
  else bad "$label: 켜진 생태계가 github-actions 하나가 아니다 — $out"; fi
done

# 주석 블록은 --lang 과 상관없이 같은 파일이다. 한 설치본으로 본다.
y="$T/repo-all/.github/dependabot.yml"
all=$(sed -n 's/^ALL_LANGS="\(.*\)"$/\1/p' "$KIT/install.sh")
[ -n "$all" ] || bad "install.sh 에서 ALL_LANGS 를 읽지 못했다"
if [ -f "$y" ]; then
  out=$(python3 "$T/check.py" "$y" examples "$all" 2>&1)
  if [ $? -eq 0 ]; then ok "어댑터 언어마다 주석 블록이 있고, 풀면 YAML 로 읽혀 그 생태계가 켜진다 ($(printf '%s\n' "$out" | tail -1))"
  else bad "주석 블록:"; printf '%s\n' "$out" | sed 's/^/      /'; fi
fi

rm -rf "$T"
exit $fail
