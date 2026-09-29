#!/usr/bin/env bash
# --lang 설치에서 gates.yml 의 언어 필터(common/ci/filter-langs.awk)가 남는 스텝의 설명 주석을 지우지 않는가.
#
# 이 테스트가 있는 이유: 필터는 설치하지 않는 언어의 스텝을 건너뛰는 동안 6칸 들여쓴 주석 줄을 버렸다.
# 그 주석이 다음 스텝의 설명이어도 버려서, 앞 언어를 뺀 설치에서 뒤 스텝의 설명이 사라졌다(이슈 #106).
# 스텝과 동작은 남고 워크플로 안의 근거만 없어지므로 실행 결과로는 드러나지 않는다.
#
# 필터를 직접 부르지 않고 설치기를 거쳐 부른다(`install.sh <레포> --lang <남길 언어>`). 보는 것:
#   · go · jvm · py · ts 가운데 한~세 개를 남기는 14개 조합마다 설치된 gates.yml 이 YAML 로 읽힌다
#   · detect 밖의 잡마다, 설치본의 스텝을 YAML 로 읽은 목록이 원본에서 필터가 뺀 스텝을 제외한 목록과
#     같다. PyYAML 은 같은 키가 두 번 나와도 읽으므로, 필터가 뺀 스텝의 본문 줄이 앞 스텝에 붙어
#     남은 것은 읽히는지만 봐서는 드러나지 않는다
#   · 원본에서 스텝 바로 앞에 있는 주석 묶음은 그 스텝이 남으면 그 스텝 머리 바로 앞에 그대로 남고,
#     빠지면 없다. 스텝의 언어는 스텝의 `- if: needs.detect.outputs.<언어>` 와 잡의 `if:` 에서
#     읽는다(node 는 ts)
#   · 필터가 빼는 스텝의 본문 한가운데 있는 6칸 주석은 그 스텝과 함께 지워지고, 그 뒤의 본문 줄도
#     남지 않는다. 그 스텝이 남으면 주석도 제자리에 남는다. 킷 사본의 gates.yml 에 그런 주석을 넣고 본다
#   · 필터가 빼는 스텝 뒤의 6칸 주석은, 뒤에 스텝 머리가 오지 않으면(잡 머리 · 2칸 주석 · 파일 끝)
#     그 스텝과 함께 지워진다. 그 스텝이 남으면 주석도 남는다. 킷 사본의 gates.yml 에 넣고 본다
#   · 설치본의 워크플로 env 에 남은 변수는 설치본 어딘가에서 쓰인다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
python3 -c 'import yaml' 2>/dev/null || { bad "python3 의 yaml 모듈이 없다 — 설치본이 YAML 로 읽히는지 볼 수 없다"; exit 1; }

T=$(mktemp -d)

# $1=킷 경로  $2=남길 언어(쉼표). 설치된 gates.yml 경로를 출력한다. 설치가 실패하면 빈 줄.
install_lang() {
  local R
  R=$(mktemp -d "$T/repo.XXXXXX")
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  git -C "$R" commit -q --allow-empty -m init
  bash "$1/install.sh" "$R" --lang "$2" > "$R.log" 2>&1 || { echo ""; return 1; }
  echo "$R/.github/workflows/gates.yml"
}

cat > "$T/check.py" <<'PY'
import re, sys, yaml

src, out, keep = sys.argv[1], sys.argv[2], set(sys.argv[3].split(","))
drop = {"go", "jvm", "py", "ts"} - keep
if "ts" in drop:
    drop.add("node")                       # CI 는 ts 어댑터의 출력을 node 라 부른다
srcl = open(src, encoding="utf-8").read().split("\n")
outl = open(out, encoding="utf-8").read().split("\n")
try:
    yaml.safe_load("\n".join(outl))
except Exception as e:
    print("✗ YAML 로 읽히지 않는다: " + str(e).splitlines()[0])
    sys.exit(1)

def contains(hay, needle):
    n = len(needle)
    return any(hay[i:i + n] == needle for i in range(len(hay) - n + 1))

def lang(cond):
    m = re.match(r"needs\.detect\.outputs\.([a-z]+) ==", str(cond or ""))
    return m.group(1) if m else None

bad = 0
# detect 밖의 잡마다 스텝을 견준다. detect 는 필터가 탐지문과 출력을 고치는 잡이라 뺀다.
S, O = yaml.safe_load("\n".join(srcl)), yaml.safe_load("\n".join(outl))

# 워크플로 env 의 변수마다 설치본 어딘가에서 쓰인다. 필터는 언어 전용 변수를 이름으로 찾으므로(ENVOF),
# 그 이름이 gates.yml 의 변수 이름과 다르면 빠진 언어의 변수가 쓰는 곳 없이 남는다.
for k in (O.get("env") or {}):
    body = "\n".join(l for l in outl if not re.match(rf"^  {re.escape(k)}:", l))
    if not re.search(rf"(env\.|\$\{{?){re.escape(k)}\b", body):
        print(f"✗ 워크플로 env 에 쓰는 곳이 없는 변수가 남았다: {k}")
        bad = 1
for name, job in S["jobs"].items():
    if name == "detect":
        continue
    if lang(job.get("if")) in drop:
        if name in O["jobs"]:
            print(f"✗ 빠지는 잡 {name} 이 남았다")
            bad = 1
        continue
    want = [s for s in job.get("steps", []) if lang(s.get("if")) not in drop]
    got = (O["jobs"].get(name) or {}).get("steps") or []
    for k in range(max(len(got), len(want))):
        g = got[k] if k < len(got) else None
        if g != (want[k] if k < len(want) else None):
            print(f"✗ {name} 잡의 {k + 1}번째 스텝이 원본에서 필터가 뺀 스텝을 제외한 것과 다르다: {str(g)[:90]}")
            bad = 1
            break

# 원본의 스텝마다 바로 앞의 주석 묶음(6칸 주석과 그 사이 빈 줄)을 모은다.
units, injobs, joblang = [], False, None
for i, l in enumerate(srcl):
    if l == "jobs:":
        injobs = True
        continue
    if not injobs:
        continue
    if re.match(r"^  [a-z_-]+:$", l):
        joblang = None
        continue
    m = re.match(r"^    if: needs\.detect\.outputs\.([a-z]+) ==", l)
    if m:
        joblang = m.group(1)
        continue
    if l.startswith("      - "):
        j, block = i - 1, []
        while j >= 0 and (srcl[j].startswith("      #") or srcl[j] == ""):
            block.insert(0, srcl[j])
            j -= 1
        while block and block[0] == "":
            block.pop(0)
        if not any(b.startswith("      #") for b in block):
            continue
        m = re.match(r"^      - if: needs\.detect\.outputs\.([a-z]+) ==", l)
        steplang = m.group(1) if m else None
        units.append((block, (steplang in drop) or (joblang in drop), l))

kept_blocks = [b for b, dropped, _ in units if not dropped]
for block, dropped, head in units:
    first = block[0].strip()[:60]
    # 남는 스텝은 묶음 뒤에 그 스텝 머리 줄까지 붙여 찾는다. 묶음만 찾으면 주석이 스텝 머리 뒤로
    # 밀려도 통과한다.
    if not dropped and not contains(outl, block + [head]):
        print(f"✗ 남는 스텝({head.strip()[:50]})의 앞 주석이 사라졌거나 그 스텝 머리 바로 앞에 없다: {first}")
        bad = 1
    if dropped and block not in kept_blocks and contains(outl, block):
        print(f"✗ 빠지는 스텝({head.strip()[:50]})의 앞 주석이 남았다: {first}")
        bad = 1
n_keep = sum(1 for _, d, _ in units if not d)
print(f"묶음 {len(units)} · 남는 스텝 앞 {n_keep} · 빠지는 스텝 앞 {len(units) - n_keep}")
sys.exit(bad)
PY

for keep in go jvm py ts go,jvm go,py go,ts jvm,py jvm,ts py,ts go,jvm,py go,jvm,ts go,py,ts jvm,py,ts; do
  y=$(install_lang "$KIT" "$keep")
  if [ -z "$y" ]; then bad "--lang $keep: 설치가 실패했다"; continue; fi
  out=$(python3 "$T/check.py" "$KIT/common/ci/gates.yml" "$y" "$keep" 2>&1)
  if [ $? -eq 0 ]; then ok "--lang $keep: 스텝이 원본에서 필터가 뺀 것만 빠지고, 스텝 앞 주석이 스텝과 함께 남거나 지워진다 ($(printf '%s\n' "$out" | tail -1))"
  else bad "--lang $keep:"; printf '%s\n' "$out" | sed 's/^/      /'; fi
done

TAIL='꼬리 주석(tests/filter-langs.sh 가 넣었다)'
# $1=사본 이름(영문)  $2=gates.yml 을 바꾸는 awk 프로그램. 변수 c 는 6칸 꼬리 주석 한 줄이다.
# 킷을 복사해 그 사본의 gates.yml 만 바꾸고, 사본 경로를 출력한다.
kit_copy() {
  local K="$T/kit-$1"
  mkdir -p "$K"
  tar -C "$KIT" --exclude=.git -cf - . | tar -C "$K" -xf -
  awk -v c="      # $TAIL" "$2" "$KIT/common/ci/gates.yml" > "$K/common/ci/gates.yml"
  echo "$K"
}

# 필터가 빼는 스텝의 본문 한가운데 6칸 주석. YAML 은 그 자리의 주석을 허용한다. 필터가 거기서
# 건너뛰기를 끝내면 그 스텝의 나머지 줄이 남아 워크플로가 깨진다.
K2=$(kit_copy mid '{ print } /^        name: install golangci-lint$/ { print "      # 스텝 본문 한가운데의 6칸 주석(tests/filter-langs.sh 가 넣었다)" }')
if ! grep -q '^      # 스텝 본문 한가운데의 6칸 주석' "$K2/common/ci/gates.yml"; then
  bad "go 스텝 본문에 주석을 넣지 못했다 — gates.yml 의 install golangci-lint 스텝이 바뀌었나"
else
  # go 만 뺀다. 다음 스텝(JVM)이 남아야, 그 주석을 모아 두었다가 다음 스텝 앞에 내보내는 필터가 드러난다.
  y=$(install_lang "$K2" "jvm,py,ts")
  # 그 스텝의 줄만 센다 — 스텝 이름 · 설치 명령 · 넣은 주석. 다른 스텝의 주석도 golangci-lint 를 적는다.
  left=$(grep -c -e 'name: install golangci-lint' -e 'golangci-lint/v2/cmd/golangci-lint@' -e '스텝 본문 한가운데' "$y" 2>/dev/null)
  out=$(python3 "$T/check.py" "$K2/common/ci/gates.yml" "$y" "jvm,py,ts" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ "$left" = 0 ]; then
    ok "go 스텝 본문 한가운데의 6칸 주석: go 를 뺀 설치에서 그 스텝이 끝까지 지워지고 나머지 스텝은 원본과 같다"
  else
    bad "go 스텝 본문 한가운데의 6칸 주석: go 를 뺀 설치에 그 스텝의 줄이 ${left:-?}개 남았거나 설치본이 원본과 다르다"
    [ $rc -eq 0 ] || printf '%s\n' "$out" | sed 's/^/      /'
  fi
  # 그 스텝이 남는 설치에서는 주석이 제자리에 있어야 한다. 모았다가 다음 스텝 머리에서 출력하면
  # 스텝 본문 뒤로 밀린다.
  y=$(install_lang "$K2" "go,py")
  next_line=$(awk '/^        name: install golangci-lint$/ { getline; print; exit }' "$y" 2>/dev/null)
  if [ "$next_line" = "      # 스텝 본문 한가운데의 6칸 주석(tests/filter-langs.sh 가 넣었다)" ]; then
    ok "go 스텝 본문 한가운데의 6칸 주석: go 를 남긴 설치에서 제자리에 있다"
  else
    bad "go 스텝 본문 한가운데의 6칸 주석: go 를 남긴 설치에서 제자리에 없다 — name 줄 다음이 [${next_line}]"
  fi
fi

# 필터가 빼는 스텝 뒤의 6칸 주석. 뒤에 스텝 머리가 오지 않으면 그 주석이 설명할 스텝은 앞의 빠진
# 스텝뿐이다. security 잡의 마지막 스텝(node) 뒤와, 파일 끝에 덧붙인 node 스텝 뒤에 넣고 본다.
# $1=사본 이름  $2=자리  $3=gates.yml 을 바꾸는 awk 프로그램
tail_case() {
  local K y n left out rc
  K=$(kit_copy "$1" "$3")
  n=$(grep -c "$TAIL" "$K/common/ci/gates.yml")
  if [ "$n" = 0 ]; then bad "필터가 빼는 스텝 뒤의 6칸 주석($2): 주석을 넣지 못했다 — gates.yml 의 trace 잡이 바뀌었나"; return; fi
  y=$(install_lang "$K" "go,jvm,py")
  left=$(grep -c "$TAIL" "$y" 2>/dev/null)
  out=$(python3 "$T/check.py" "$K/common/ci/gates.yml" "$y" "go,jvm,py" 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ "$left" = 0 ]; then
    ok "필터가 빼는 스텝 뒤의 6칸 주석($2): ts 를 뺀 설치에서 그 스텝과 함께 지워진다"
  else
    bad "필터가 빼는 스텝 뒤의 6칸 주석($2): ts 를 뺀 설치에 ${left:-?}줄 남았거나 설치본이 원본과 다르다"
    [ $rc -eq 0 ] || printf '%s\n' "$out" | sed 's/^/      /'
  fi
  y=$(install_lang "$K" "jvm,py,ts")
  left=$(grep -c "$TAIL" "$y" 2>/dev/null)
  if [ "$left" = "$n" ]; then ok "필터가 빼는 스텝 뒤의 6칸 주석($2): ts 를 남긴 설치에서는 남는다"
  else bad "필터가 빼는 스텝 뒤의 6칸 주석($2): ts 를 남긴 설치에 ${left:-?}줄 남았다(넣은 것 ${n}줄)"; fi
}
tail_case jobhead "잡 머리 앞" '/^  trace:$/ { print c } { print }'
tail_case jobnote "2칸 주석 앞" '/^  trace:$/ { print c; print ""; print "  # trace 잡(tests/filter-langs.sh 가 넣었다)" } { print }'
tail_case eof "파일 끝" '{ print } END { print "      - if: needs.detect.outputs.node == '\''true'\''"; print "        run: echo node"; print c }'

rm -rf "$T"
exit $fail
