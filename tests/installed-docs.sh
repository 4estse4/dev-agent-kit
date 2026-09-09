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
# **설치가 실패하면 그 자리에서 죽는다.** 종료코드를 버리면 빈 레포를 훑고
# "전부 실재한다" 를 찍는다(실측). 부재는 통과가 아니다.
if ! out=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent "$R" 2>&1); then
  echo "  ✗ 설치가 실패해 아무것도 검사하지 못했다"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
  exit 1
fi
[ -d "$R/.ai-kit" ] || { echo "  ✗ 설치 후에도 .ai-kit 이 없다 — 검사할 것이 없다"; exit 1; }

# ① 설치본이 가리키는 킷 경로가 그 레포에 실제로 있나
python3 - "$R" <<'PY' || fail=1
import re, sys, os, subprocess
R = sys.argv[1]; bad = 0
# **확장자로 고르지 않는다.** `.md`·`.yml`·`.json` 만 보던 탓에 `.sh` 와 훅 파일
# (`pre-commit`·`pre-push`)이 통째로 검사 밖이었다 — 킷 경로를 가장 많이 적는 자리다.
# 설치본 전부를 보고, 읽을 수 없는 것(바이너리)만 건너뛴다.
found = subprocess.run(['find', R, '-type', 'f'], capture_output=True, text=True).stdout.split()
for f in found:
    if '/.git/' in f:
        continue
    try:
        text = open(f, encoding='utf-8').read()
    except (UnicodeDecodeError, OSError):
        continue
    # `common/`·`.ai-kit/` 만 보면 소유 규칙과 상호참조가 실제로 쓰는 어휘
    # (`.claude/skills/…`·`docs/process/…`)가 통째로 검사 밖이다 — 15라운드에 거짓이던
    # 자리가 바로 그 어휘였다.
    # **백틱 안만 보면 안 된다.** `settings.json` 이 백틱 없이 적은 옛 경로가 통과했다 —
    # 개명 뒤에도 초록이었고, 그 파일은 설치되므로 모든 프로젝트가 없는 경로를 가리켰다.
    for m in re.findall(r'(?<![\w/-])((?:common|\.ai-kit|\.claude|docs/process)/[\w./|-]+)', text):
        m = m.rstrip('.')            # 문장 끝 마침표가 붙어 온다
        m = m.split('|')[0]          # `.claude/skills|agents|hooks` 같은 표기
        if not os.path.exists(os.path.join(R, m)):
            print(f"  ✗ {f[len(R)+1:]} 가 없는 경로를 가리킨다 — {m}"); bad = 1
sys.exit(bad)
PY
[ "$fail" = 0 ] && echo "  ✓ 설치본의 킷 경로 참조가 전부 실재한다"

# ② 미리보기가 내는 낱말과 문서가 쓰는 낱말이 같나
# **옛 낱말을 손으로 적지 않는다.** 적으면 다음 개명에 안 따라오고, 그게 이 검사가
# 잡으려는 결함과 같은 클래스다. git 히스토리에서 이 줄이 예전에 쓰던 낱말을 꺼낸다.
old=0
now=$(bash "$KIT/install.sh" --hooks --dry-run "$R" 2>&1 | sed -n 's/.*지금 설치하면 — //p' \
      | tr '·' '\n' | sed 's/[0-9]//g; s/^ *//; s/ *$//' | grep -v '^$' | sort -u)
was=$(git -C "$KIT" log --format=%H -- install.sh \
      | while read -r c; do
          git -C "$KIT" show "$c:install.sh" 2>/dev/null \
            | sed -n 's/.*echo "지금 설치하면 — \(.*\)"/\1/p' \
            | tr '·' '\n' | sed 's/\${[^}]*}//g; s/^ *//; s/ *$//' | grep -v '^$'
        done | sort -u)
while IFS= read -r w; do
  [ -n "$w" ] || continue
  printf '%s\n' "$now" | grep -qxF "$w" && continue          # 지금도 쓰는 낱말
  # **칸 이름으로 쓰인 자리만 본다.** 옛 낱말 중에는 `그대로` 처럼 일상어도 있어서
  # 그냥 찾으면 "출력을 그대로 붙인다" 같은 문장이 걸린다. 칸은 뒤에 수가 온다.
  if grep -rqnE "${w}[[:space:]]+[0-9]" "$KIT/README.md" "$KIT/CLAUDE.md" "$KIT/common/docs/" 2>/dev/null; then
    echo "  ✗ 문서가 설치기가 더는 안 쓰는 낱말을 쓴다 — 「${w}」"; fail=1; old=1
  fi
done <<< "$was"
[ "$old" = 0 ] && echo "  ✓ 문서의 낱말이 설치기 출력과 같은 세대다 ($(printf '%s ' ${now}))"

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
