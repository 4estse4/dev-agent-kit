#!/usr/bin/env bash
# --lang 설치에서 gates.yml 의 언어 필터(common/ci/filter-langs.awk)가 남는 스텝의 설명 주석을 지우지 않는가.
#
# 이 테스트가 있는 이유: 필터는 설치하지 않는 언어의 스텝을 건너뛰는 동안 6칸 들여쓴 주석 줄을 버렸다.
# 그 주석이 다음 스텝의 설명이어도 버려서, 앞 언어를 뺀 설치에서 뒤 스텝의 설명이 사라졌다(이슈 #106).
# 스텝과 동작은 남고 워크플로 안의 근거만 없어지므로 실행 결과로는 드러나지 않는다.
#
# 필터를 직접 부르지 않고 설치기를 지나간다(`install.sh <레포> --lang <남길 언어>`). 보는 것:
#   · go · jvm · py · ts 가운데 한~세 개를 남기는 14개 조합마다 설치된 gates.yml 이 YAML 로 읽힌다
#   · 원본에서 스텝 바로 앞에 있는 주석 묶음은 그 스텝이 남으면 그대로 남고, 떨어지면 없다.
#     스텝의 언어는 스텝의 `- if: needs.detect.outputs.<언어>` 와 잡의 `if:` 에서 읽는다(node 는 ts)
#   · 떨어뜨리는 스텝의 본문 한가운데 있는 6칸 주석은 그 스텝과 함께 지워지고, 그 뒤의 본문 줄도
#     남지 않는다. 킷 사본의 gates.yml 에 그런 주석을 넣고 go 를 뺀 설치로 본다
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
        units.append((block, (steplang in drop) or (joblang in drop), l.strip()))

kept_blocks = [b for b, dropped, _ in units if not dropped]
bad = 0
for block, dropped, head in units:
    first = block[0].strip()[:60]
    if not dropped and not contains(outl, block):
        print(f"✗ 남는 스텝({head[:50]})의 앞 주석이 사라졌다: {first}")
        bad = 1
    if dropped and block not in kept_blocks and contains(outl, block):
        print(f"✗ 떨어지는 스텝({head[:50]})의 앞 주석이 남았다: {first}")
        bad = 1
n_keep = sum(1 for _, d, _ in units if not d)
print(f"묶음 {len(units)} · 남는 스텝 앞 {n_keep} · 떨어지는 스텝 앞 {len(units) - n_keep}")
sys.exit(bad)
PY

for keep in go jvm py ts go,jvm go,py go,ts jvm,py jvm,ts py,ts go,jvm,py go,jvm,ts go,py,ts jvm,py,ts; do
  y=$(install_lang "$KIT" "$keep")
  if [ -z "$y" ]; then bad "--lang $keep: 설치가 실패했다"; continue; fi
  out=$(python3 "$T/check.py" "$KIT/common/ci/gates.yml" "$y" "$keep" 2>&1)
  if [ $? -eq 0 ]; then ok "--lang $keep: YAML 로 읽히고 스텝 앞 주석이 스텝과 함께 남거나 지워진다 ($(printf '%s\n' "$out" | tail -1))"
  else bad "--lang $keep:"; printf '%s\n' "$out" | sed 's/^/      /'; fi
done

# 떨어뜨리는 스텝의 본문 한가운데 6칸 주석. YAML 은 그 자리의 주석을 허용한다. 필터가 거기서
# 건너뛰기를 끝내면 그 스텝의 나머지 줄이 남아 워크플로가 깨진다.
K2="$T/kit2"; mkdir -p "$K2"
tar -C "$KIT" --exclude=.git -cf - . | tar -C "$K2" -xf -
awk '{ print } /^        name: install golangci-lint$/ { print "      # 스텝 본문 한가운데의 6칸 주석(tests/filter-langs.sh 가 넣었다)" }' \
  "$KIT/common/ci/gates.yml" > "$K2/common/ci/gates.yml"
if ! grep -q '^      # 스텝 본문 한가운데의 6칸 주석' "$K2/common/ci/gates.yml"; then
  bad "go 스텝 본문에 주석을 넣지 못했다 — gates.yml 의 install golangci-lint 스텝이 바뀌었나"
else
  # go 만 뺀다. 다음 스텝(JVM)이 남아야, 그 주석을 들고 있다가 다음 스텝 앞에 내보내는 필터가 드러난다.
  y=$(install_lang "$K2" "jvm,py,ts")
  # 그 스텝의 줄만 센다 — 스텝 이름 · 설치 명령 · 넣은 주석. 다른 스텝의 주석도 golangci-lint 를 든다.
  left=$(grep -c -e 'name: install golangci-lint' -e 'golangci-lint/v2/cmd/golangci-lint@' -e '스텝 본문 한가운데' "$y" 2>/dev/null)
  if [ -n "$y" ] && python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$y" 2>/dev/null && [ "$left" = 0 ]; then
    ok "go 스텝 본문 한가운데의 6칸 주석: go 를 뺀 설치에서 그 스텝이 끝까지 지워지고 YAML 로 읽힌다"
  else
    bad "go 스텝 본문 한가운데의 6칸 주석: go 를 뺀 설치에 그 스텝의 줄이 ${left:-?}개 남았거나 YAML 로 읽히지 않는다"
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

rm -rf "$T"
exit $fail
