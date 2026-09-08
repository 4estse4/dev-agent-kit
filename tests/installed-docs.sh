#!/usr/bin/env bash
# 설치된 레포에서 킷의 문서가 거짓말을 하지 않는가.
#
# 이 테스트가 있는 이유: 열다섯 라운드 동안 **고친 것의 파급이 문서에 안 간 결함이 여섯 번**
# 났다 — README 의 예시 출력이 세 세대 전 낱말이었고, 설치되는 kit-guide 가 바뀐 소유
# 규칙을 몰랐고, `--help` 헤더가 거짓이었고, tool-versions 가 없는 경로를 가리켰다.
# 킷 규칙에 "이름을 옮겼으면 옛 이름을 grep 한다" 가 있었지만 `사람` 이었고, 사람이 코드에만
# grep 을 걸었다. 그래서 기계가 건다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
R=$(mktemp -d)/repo; mkdir -p "$R"
git init -q "$R"; git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
bash "$KIT/install.sh" --hooks --templates --lint --ci --agent "$R" >/dev/null 2>&1

# ① 설치본이 가리키는 킷 경로가 그 레포에 실제로 있나
python3 - "$R" <<'PY' || fail=1
import re, sys, os, subprocess
R = sys.argv[1]; bad = 0
found = subprocess.run(
    ['find', R, '-type', 'f', '(', '-name', '*.md', '-o', '-name', '*.yml',
     '-o', '-name', 'tool-versions', '-o', '-name', '*.json', ')'],
    capture_output=True, text=True).stdout.split()
for f in found:
    if '/.git/' in f:
        continue
    for m in re.findall(r'`?((?:common|\.ai-kit)/[\w./-]+)`?', open(f, errors='ignore').read()):
        if not os.path.exists(os.path.join(R, m)):
            print(f"  ✗ {f[len(R)+1:]} 가 없는 경로를 가리킨다 — {m}"); bad = 1
sys.exit(bad)
PY
[ "$fail" = 0 ] && echo "  ✓ 설치본의 킷 경로 참조가 전부 실재한다"

# ② 미리보기가 내는 낱말과 문서가 쓰는 낱말이 같나
words=$(bash "$KIT/install.sh" --hooks --dry-run "$R" 2>&1 \
        | sed -n 's/.*지금 설치하면 — //p' | tr '·' '\n' | sed 's/[0-9]//g; s/^ *//; s/ *$//' | grep -v '^$')
old=0
for w in "새 파일" "내용이 다름" "킷이 안 놓음" "옆에 놓임" "건너뜀 [0-9]"; do
  if grep -rqn "$w" "$KIT/README.md" "$KIT/common/docs/" 2>/dev/null; then
    echo "  ✗ 문서가 설치기가 더는 안 쓰는 낱말을 쓴다 — 「${w}」"; fail=1; old=1
  fi
done
[ "$old" = 0 ] && echo "  ✓ 문서의 낱말이 설치기 출력과 같은 세대다 ($(echo "$words" | tr '\n' ' '))"

# ③ README 의 예시 출력이 실제로 나올 수 있는 것인가
if grep -q '지금 설치하면' "$KIT/README.md"; then
  # 숫자는 상황마다 다르다 — **칸 이름과 순서**만 본다. 그것이 개명에 안 따라오는 부분이다.
  cols() { grep -o '지금 설치하면 — .*' | head -1 | sed 's/[0-9]\{1,\}//g; s/  */ /g; s/ *· */·/g; s/ *$//'; }
  ex=$(cols < "$KIT/README.md")
  re=$(bash "$KIT/install.sh" --hooks --dry-run "$R" 2>&1 | cols)
  if [ "$ex" = "$re" ]; then echo "  ✓ README 예시가 지금 형식과 같다"
  else echo "  ✗ README 예시의 칸 이름·순서가 지금과 다르다"; echo "      README [$ex]"; echo "      실제   [$re]"; fail=1; fi
fi
exit $fail
