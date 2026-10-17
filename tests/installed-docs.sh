#!/usr/bin/env bash
# 설치된 레포에서 킷의 문서가 거짓말을 하지 않는가.
#
# 이 테스트가 있는 이유: 열다섯 라운드 동안 **고친 것이 문서에 반영되지 않은 결함이 여섯 번**
# 생겼다 — README 의 예시 출력이 세 세대 전 낱말이었고, 설치되는 kit-guide 가 바뀐 소유
# 규칙을 몰랐고, `--help` 헤더가 거짓이었고, tool-versions 가 없는 경로를 가리켰다.
# 킷 규칙에 "이름을 옮겼으면 옛 이름을 grep 한다" 가 있었지만 `막는 것 없음` 이었고, 사람이 코드에만
# grep 을 실행했다. 그래서 기계가 실행한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
R=$(mktemp -d)/repo; mkdir -p "$R"
git init -q "$R"; git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
# **설치가 실패하면 그 자리에서 멈춘다.** 종료코드를 버리면 빈 레포를 훑고
# "전부 실재한다" 를 출력한다(실제로 확인함). 부재는 통과가 아니다.
if ! out=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent "$R" 2>&1); then
  echo "  ✗ 설치가 실패해 아무것도 검사하지 못했다"; printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
  exit 1
fi
[ -d "$R/.kit" ] || { echo "  ✗ 설치 후에도 .kit 이 없다 — 검사할 것이 없다"; exit 1; }
# 세션이 PR 본문 조각을 두는 자리(`.kit/drafts/`)는 설치 직후에는 없고, 설치된 `drafts.sh` 를 처음 부를 때 생긴다.
# 그 자리를 가리키는 설치된 파일을 거짓으로 세지 않도록 세션이 하듯 한 번 부른 트리에서 본다. 부르지 못하면 멈춘다 —
# 그 스크립트가 그 자리를 만들지 않게 바뀌면, 그 자리를 가리키는 설치된 파일이 아래 검사에서 실패한다.
(cd "$R" && bash .claude/skills/open-pr/drafts.sh pr-body >/dev/null) \
  || { echo "  ✗ 설치된 drafts.sh 를 부르지 못해 조각 자리를 만들지 못했다"; exit 1; }

# ① 설치된 파일이 가리키는 킷 경로가 그 레포에 실제로 있나
python3 - "$R" "$KIT" <<'PY' || fail=1
import re, sys, os, subprocess
R = sys.argv[1]; bad = 0
KIT = set(subprocess.run(['git', '-C', sys.argv[2], '-c', 'core.quotePath=false', 'ls-files'],
                         capture_output=True, text=True, check=True).stdout.split('\n'))
# **프로젝트가 만드는 파일은 설치 직후에 없다.** 그 목록은 설치된 kit-guide 2절 「프로젝트가 채워야
# 하는 것」 표의 첫 칸이다. 여기 따로 적지 않는다 — 두 벌이면 어긋나고, 문서에 없는 파일을 가리키면
# 그대로 실패해야 한다.
guide = open(os.path.join(R, 'docs/process/kit-guide.md'), encoding='utf-8').read()
part = re.search(r'(?ms)^## 2\..*?(?=^## )', guide)
PROJECT = set(re.findall(r'(?m)^\| `([^`]+)`', part.group(0))) if part else set()
# **확장자로 고르지 않는다.** `.md`·`.yml`·`.json` 만 보던 탓에 `.sh` 와 훅 파일
# (`pre-commit`·`pre-push`)이 통째로 검사 밖이었다 — 킷 경로를 가장 많이 적는 자리다.
# 설치된 파일 전부를 보고, 읽을 수 없는 것(바이너리)만 건너뛴다.
found = subprocess.run(['find', R, '-type', 'f'], capture_output=True, text=True).stdout.split()
for f in found:
    if '/.git/' in f:
        continue
    try:
        text = open(f, encoding='utf-8').read()
    except (UnicodeDecodeError, OSError):
        continue
    # `common/`·`.kit/` 만 보면 소유 규칙과 상호참조가 실제로 쓰는 어휘
    # (`.claude/skills/…`·`docs/process/…`)가 통째로 검사 밖이다 — 15라운드에 거짓이던
    # 자리가 바로 그 어휘였다.
    # **백틱 안만 보면 안 된다.** `settings.json` 이 백틱 없이 적은 옛 경로가 통과했다 —
    # 개명 뒤에도 이 테스트가 통과했고, 그 파일은 설치되므로 모든 프로젝트가 없는 경로를 가리켰다.
    # **`(?a)` 가 있어야 한다.** `\w` 는 파이썬에서 유니코드라 한글 음절을 문자로 세고,
    # 그래서 `…verification-stages.md에` 처럼 경로에 붙은 조사까지 경로에 넣어, 없는 경로를
    # 가리킨다고 판정했다(실제로 확인함: 그 상태에서 이 검사가 종료코드 1). 백틱 제약을 뺀 대가다 — 백틱이
    # 없으면 「경로 뒤에 공백」이라는 표기 관습도 같이 사라진다.
    # 앞의 `./` · `../` 는 떼고 레포 뿌리에서 본다 — 아래 킷 전용 경로 검사와 같다.
    for m in re.findall(r'(?a)(?<![\w/-])(?:\.\.?/)*((?:common|\.kit|\.claude|docs/process)/[\w./|-]+)', text):
        m = m.rstrip('.')            # 문장 끝 마침표가 붙어 온다
        m = m.split('|')[0]          # `.claude/skills|agents|hooks` 같은 표기
        if not os.path.exists(os.path.join(R, m)) and m not in PROJECT:
            print(f"  ✗ {f[len(R)+1:]} 가 없는 경로를 가리킨다 — {m}"); bad = 1
    # **킷에만 있는 경로.** 위 접두어 밖(`docs/` 의 나머지 · `.github/` · `tests/`)은
    # 설치된 레포에 없는 것이 정상일 수 있다 — 스킬이 만들 파일(`docs/HANDOFF.md`)이
    # 그렇다. 그래서 이쪽은 「킷에는 있는데 설치된 트리에는 없다」일 때만 실패한다.
    # 설치된 파일이 킷 자신의 기록(`docs/adr/0001-…` · `tests/…` · 킷 전용 워크플로)을
    # 가리키던 것이 이 검사 밖이었다(이슈 #61). 예외 목록을 두지 않는다.
    # 앞의 `./` · `../` 는 떼고 레포 뿌리에서 본다. 마크다운 상대 링크가 흔히 그 모양이다.
    # 디렉터리만 적은 것(`tests/`)은 킷 파일 중 그 접두어로 시작하는 것이 있으면 킷 경로다.
    # `0001-…` 처럼 줄인 이름은 실제 경로로 풀 수 없어 보지 않는다.
    for m in re.findall(r'(?a)(?<![\w/-])(?:\.\.?/)*((?:docs|\.github|tests)/[\w./-]*)', text):
        m = m.rstrip('.').rstrip('/')
        if m.startswith('docs/process'):
            continue                 # 위에서 봤다
        in_kit = m in KIT or any(k.startswith(m + '/') for k in KIT)
        if in_kit and not os.path.exists(os.path.join(R, m)):
            print(f"  ✗ {f[len(R)+1:]} 가 킷에만 있는 경로를 가리킨다 — {m}"); bad = 1
    # **킷 레포 이름.** 파일이든 PR 이든 킷 레포로 보내는 것은 같다(이슈 #61 의 결정).
    # 주소만 보면 `gh api repos/…` · `-R …` · `owner/repo#N` 을 찾지 못한다. 그래서 이름을
    # 본다. 레포 홈 주소만 둔다 — 설치된 킷이 어디서 왔는지 밝히는 자리(`.kit/README.md`)다.
    # 대소문자를 가리지 않는다. `gh api repos/4ESTSE4/Dev-Agent-Kit` 도 킷 레포를 낸다.
    # 옛 이름 `ai-native-kit` 도 본다. 레포 이름을 바꾼 뒤에도 GitHub 이 옛 이름을 새 레포로 이어 준다.
    # 홈 주소 뒤는 막을 글자로 정한다 — 영숫자 · `@` · `#` · `-`, 그리고 `/` · `.` · `:` 뒤에
    # 이어지는 경로. 뒤에 올 글자를 허용 목록으로 보던 때는
    # 쉼표 · 조사 · 끝 슬래시 · 콜론에서 오탐이 생겼다.
    for mo in re.finditer(r'(?i)4estse4/(?:dev-agent-kit|ai-native-kit)', text):
        s, e = mo.span()
        home = (text[max(0, s - 19):s].lower() == 'https://github.com/'
                and not re.match(r'(?a)[\w@#-]|[/.:][\w#-]', text[e:e + 2]))
        if not home:
            line = text[text.rfind('\n', 0, s) + 1:].split('\n')[0].strip()[:100]
            print(f"  ✗ {f[len(R)+1:]} 가 킷 레포를 가리킨다 — {line}"); bad = 1
sys.exit(bad)
PY
[ "$fail" = 0 ] && echo "  ✓ 설치된 파일의 킷 경로 참조가 전부 실재한다"

# ② 미리보기가 내는 낱말과 문서가 쓰는 낱말이 같나
# **옛 낱말을 손으로 적지 않는다.** 적으면 다음 개명 때 함께 고쳐지지 않고, 그것이 이 검사가
# 막으려는 결함과 같은 종류다. git 히스토리에서 이 줄이 예전에 쓰던 낱말을 꺼낸다.
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
  # 그냥 찾으면 "출력을 그대로 붙인다" 같은 문장도 검색 결과에 나온다. 칸은 뒤에 수가 온다.
  if grep -rqnE "${w}[[:space:]]+[0-9]" "$KIT/README.md" "$KIT/CLAUDE.md" "$KIT/common/docs/" 2>/dev/null; then
    echo "  ✗ 문서가 설치기가 더는 안 쓰는 낱말을 쓴다 — 「${w}」"; fail=1; old=1
  fi
done <<< "$was"
[ "$old" = 0 ] && echo "  ✓ 문서의 낱말이 설치기 출력과 같은 세대다 ($(printf '%s ' ${now}))"

# ③ README 의 예시 출력이 실제로 나올 수 있는 것인가
if grep -q '지금 설치하면' "$KIT/README.md"; then
  # 숫자는 상황마다 다르다 — **칸 이름과 순서**만 본다. 그것이 개명할 때 함께 고쳐지지 않는 부분이다.
  cols() { grep -o '지금 설치하면 — .*' | head -1 | sed 's/[0-9]\{1,\}//g; s/  */ /g; s/ *· */·/g; s/ *$//'; }
  ex=$(cols < "$KIT/README.md")
  re=$(bash "$KIT/install.sh" --hooks --dry-run "$R" 2>&1 | cols)
  if [ "$ex" = "$re" ]; then echo "  ✓ README 예시가 지금 형식과 같다"
  else echo "  ✗ README 예시의 칸 이름·순서가 지금과 다르다"; echo "      README [$ex]"; echo "      실제   [$re]"; fail=1; fi
fi
exit $fail
