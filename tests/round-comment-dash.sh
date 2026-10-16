#!/usr/bin/env bash
# 라운드 코멘트를 올리기 전의 줄표 검사(`claude-code/skills/open-pr/round.md` 3.4)가 접히지 않은 부분을 모두 보는가.
#
# **스킬이 적은 명령을 그대로 꺼내 실행한다.** 검사는 스킬 문서 안의 명령이라, 테스트에 따로 적은 명령을 시험하면
# 문서의 명령이 틀려도 이 테스트가 통과한다. `**게시하기 전에 \`—\` 도 본다.**` 문단 뒤의 들여쓴 블록을 꺼내
# `<코멘트 파일>` 자리에 아래 글을 넣는다.
#
# **접힌 블록이 코멘트 가운데에도 온다.** 총량에 막힌 라운드 코멘트는 바구니마다 낮음 항목을 접는다
# (`comment-format.md` 의 「총량에 막히면」). 그 뒤의 바구니와 맨 아래 제안은 접히지 않은 채 남는다. 첫 `<details>`
# 부터 지우던 검사는 그 줄들을 보지 않았다. 접은 낮음 항목도 세션이 쓴 바구니이고 3.5 보고로 사람에게 가므로
# 검사가 본다. 건너뛰는 것은 그대로 싣는 두 리뷰 전문뿐이다. 리뷰 전문 안에 접힌 블록(재현 스크립트)이 또 있어도
# 짝을 세어 바깥 블록이 끝날 때까지 건너뛴다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
fail=0
cmd=$(python3 - "$KIT/claude-code/skills/open-pr/round.md" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
i = next(k for k, x in enumerate(lines) if x.startswith('**게시하기 전에 `—` 도 본다.**'))
while not lines[i].startswith('    '):
    i += 1
block = []
while i < len(lines) and lines[i].startswith('    '):
    block.append(lines[i][4:])
    i += 1
print('\n'.join(block))
PY
)
if [ -z "$cmd" ]; then
  echo "  ✗ round.md 에서 줄표 검사 명령을 찾지 못했다"; exit 1
fi
cat > "$T/c.md" <<'EOF'
## 리뷰 2라운드 — 셀프 ***`Comment`*** · 콜드 ***`Comment`***

리뷰한 head: 0000000000000000000000000000000000000000

### 2라운드 발견

**필수**
- **높음** (콜드) `a.sh:1`: 펼친 항목 — 찾아야 한다
  → 고친다

<details>

<summary>낮음 1건</summary>

- **낮음** (셀프) `b.sh:2`: 접은 낮음 항목 — 세션이 쓴 바구니라 찾아야 한다
  → 고친다

</details>

**결정 필요**
- **중간** (콜드) `c.sh:3`: 접힌 블록 뒤의 항목
  → 접힌 블록 뒤의 줄 — 찾아야 한다
- (사람, 1라운드 발견) "사람의 글 — 고치지 않는다"

---

**제안**을 제안합니다.

---

<details>

<summary>셀프 리뷰 전문</summary>

- 리뷰 전문 — 보지 않는다

<details>

<summary>repro.sh</summary>

    echo x

</details>

- 안쪽 블록 뒤의 리뷰 전문 — 보지 않는다

</details>
EOF
out=$(cd "$T" && bash -c "${cmd//<코멘트 파일>/$T/c.md}" 2>&1)
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }
has '8: - **높음**' && echo "  ✓ 접힌 블록 앞의 줄을 찾는다" || { echo "  ✗ 접힌 블록 앞의 줄을 못 찾았다 — $out"; fail=1; }
has '22:   → 접힌 블록 뒤의 줄' && echo "  ✓ 접힌 블록 뒤의 줄을 찾는다(원래 줄 번호로)" \
  || { echo "  ✗ 접힌 블록 뒤의 줄을 못 찾았다 — $out"; fail=1; }
has '15: - **낮음** (셀프) `b.sh:2`' && echo "  ✓ 접은 낮음 항목도 찾는다(3.5 보고로 사람에게 간다)" \
  || { echo "  ✗ 접은 낮음 항목을 못 찾았다 — $out"; fail=1; }
has '- 리뷰 전문 —' && { echo "  ✗ 리뷰 전문을 봤다 — $out"; fail=1; } || echo "  ✓ 리뷰 전문은 보지 않는다"
has '안쪽 블록 뒤의 리뷰 전문' && { echo "  ✗ 리뷰 전문 안의 접힌 블록 뒤를 봤다 — $out"; fail=1; } \
  || echo "  ✓ 리뷰 전문 안의 접힌 블록 뒤도 보지 않는다"
has '사람의 글' && { echo "  ✗ 사람 인용을 봤다 — $out"; fail=1; } || echo "  ✓ 사람 인용은 보지 않는다"
rm -rf "$T"
exit "$fail"
