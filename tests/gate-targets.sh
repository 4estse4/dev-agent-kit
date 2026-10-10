#!/usr/bin/env bash
# 게이트가 바뀐 모듈을, 그리고 바뀐 모듈만 검사 대상으로 고르는가.
#
# 이 테스트가 있는 이유: gate.sh 는 find 가 낸 모듈 경로를 git 이 낸 변경 경로와 대조해
# 대상을 고른다. 그 대조가 두 가지로 어긋났고, 둘 다 "검사 대상 없음" 에 rc=0 이었다.
# 게이트는 통과라고 말하는데 그 모듈을 안 봤다.
#   · 모듈 경로를 정규식으로 썼다. `app[1]` 같은 루트는 자기 안의 파일과 안 맞았다
#   · 변경 목록을 `printf | grep -q` 로 전달했다. pipefail 아래에서 grep 이 첫 매치에서 끝나면
#     남은 목록을 쓰던 printf 가 SIGPIPE 로 종료돼 매치가 거짓이 됐다. 변경 목록이 파이프
#     버퍼보다 긴 브랜치에서 앞쪽에 정렬되는 모듈이 빠졌다
#
# 게이트를 실제로 실행한다. package.json 만 두고 node_modules 는 두지 않으므로,
# 대상으로 고른 모듈마다 ts 어댑터가 `ts(node_modules 없음)` 을 건너뜀으로 출력한다. 그 수가 대상 수다.
# 안 바뀐 모듈까지 고르는 쪽으로 망가져도 알도록, 골라야 하는 수를 정확히 본다.
# macOS 에서 Finder 로 만든 한글 이름(NFD)의 모듈 폴더는 다루지 않는다(kit-guide.md 4절).
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

mkrepo() { # 인자=모듈 루트. 저장소 경로를 낸다
  local R p
  R=$(mktemp -d)/repo; mkdir -p "$R"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  for p in "$@"; do
    mkdir -p "$R/$p"
    printf '{"name":"m","private":true}\n' > "$R/$p/package.json"
    printf 'export const a = 1;\n' > "$R/$p/index.ts"
  done
  git -C "$R" add -A; git -C "$R" commit -qm init
  git -C "$R" switch -qc change
  printf '%s' "$R"
}

change() { # $1=저장소  나머지=바꾸거나 새로 만들 경로. 한 커밋으로 남긴다
  local R="$1" p; shift
  for p in "$@"; do
    mkdir -p "$R/$(dirname "$p")"
    printf 'export const a = 2;\n' > "$R/$p"
  done
  git -C "$R" add -A; git -C "$R" commit -qm change
}

expect() { # $1=설명  $2=골라야 하는 모듈 수  $3=저장소
  local out got
  # 세션 표시를 지운다 — 세션 안에서는 게이트가 KIT_ALLOW_MISSING_TOOLS 를 받지 않는다(tests/session-escapes.sh)
  out=$(cd "$3" && env -u CLAUDE_CODE_CHILD_SESSION KIT_ALLOW_MISSING_TOOLS=1 bash "$KIT/common/gate/gate.sh" --base main 2>&1)
  got=$(printf '%s\n' "$out" | grep -o 'ts(node_modules 없음)' | wc -l | tr -d ' ')
  if [ "$got" = "$2" ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1 — 대상이 $2개여야 하는데 ${got}개다:"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1
  fi
}

R=$(mkrepo svc);      change "$R" svc/index.ts;      expect "ASCII 모듈 루트" 1 "$R"
R=$(mkrepo 서비스);   change "$R" 서비스/index.ts;   expect "한글 모듈 루트" 1 "$R"
R=$(mkrepo 'app[1]'); change "$R" 'app[1]/index.ts'; expect "대괄호 든 모듈 루트" 1 "$R"
# 대조가 너무 넓어지는 회귀는 여기서만 드러난다. 앞부분 끝의 / 를 빠뜨리면 svc 가
# svc2/ 의 변경에도 맞는다.
R=$(mkrepo svc svc2); change "$R" svc2/index.ts;     expect "안 바뀐 모듈은 고르지 않는다" 1 "$R"
# 모듈 뒤로 정렬되는 경로에 둔다. 매치 뒤에 남은 목록이 받는 쪽이 미리 읽는 양보다 커야
# 앞쪽이 SIGPIPE 로 종료된다. 파이프 버퍼(64KB)를 조금 넘는 것으로는 모자란다 — 리눅스의 mawk 는 입력을 크게 미리
# 읽어서, 목록이 100KB 남짓일 때는 awk 에 파이프로 전달하는 회귀를 찾아내지 못했다(실제로 확인함). 경로를
# 20,000개 두면 목록이 700KB 를 넘는다.
R=$(mkrepo svc); mkdir -p "$R/zz/src/components"
for ((i = 1; i <= 20000; i++)); do : > "$R/zz/src/components/Component$i.tsx"; done
change "$R" svc/index.ts; expect "변경 목록이 아주 긴 브랜치의 모듈" 1 "$R"

exit $fail
