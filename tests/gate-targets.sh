#!/usr/bin/env bash
# 게이트가 바뀐 모듈을, 그리고 바뀐 모듈만 검사 대상으로 고르는가 — 이름이 평범하지 않을 때.
#
# 이 테스트가 있는 이유: gate.sh 는 find 가 낸 모듈 경로를 git 이 낸 변경 경로와 대조해
# 대상을 고른다. 그 대조가 여러 가지로 어긋났고, 전부 "검사 대상 없음" 에 rc=0 이었다.
# 게이트는 통과라고 말하는데 그 모듈을 안 봤다.
#   · 모듈 경로를 정규식으로 썼다. `app[1]` 같은 루트는 자기 안의 파일과 안 맞았다
#   · macOS 에서 디스크의 이름은 NFD(자모)인데 git 에는 NFC(음절)로 기록되면 바이트가 달랐다
#   · 변경 목록을 `printf | grep -q` 로 넘겼다. pipefail 아래에서 grep 이 첫 매치에서 끝나면
#     남은 목록을 쓰던 printf 가 SIGPIPE 로 죽어 매치가 거짓이 됐다. 변경 목록이 파이프
#     버퍼보다 긴 브랜치에서 앞쪽에 정렬되는 모듈이 빠졌다
#   · NFD 를 맞추려고 변경 목록 전체를 macOS 의 iconv 에 넣었더니, 이모지 같은 4바이트
#     문자에서 iconv 가 멈춰 그 뒤의 목록이 사라졌다
#
# 게이트를 실제로 돌린다. package.json 만 두고 node_modules 는 두지 않으므로, 대상으로
# 잡힌 모듈마다 ts 어댑터가 `ts(node_modules 없음)` 을 건너뜀으로 찍는다. 그 수가 대상 수다.
# 안 바뀐 모듈까지 잡는 쪽으로 망가져도 알도록, 잡혀야 하는 수를 정확히 본다.
# NFD 경우는 macOS 에서만 돈다. 리눅스의 git 은 디스크의 바이트를 그대로 기록하므로 둘이
# 어긋나지 않는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

mkrepo() { # $1=커밋할 때의 core.precomposeUnicode  나머지=모듈 루트. 저장소 경로를 낸다
  local pc="$1" R p; shift
  R=$(mktemp -d)/repo; mkdir -p "$R"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  # true 는 macOS 의 git init 이 켜는 값이다. 이 값으로 커밋하면 NFD 이름이 NFC 로 기록되고,
  # false 면 NFD 그대로 기록된다.
  git -C "$R" config core.precomposeUnicode "$pc"
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

expect() { # $1=설명  $2=잡혀야 하는 모듈 수  $3=저장소
  local out got
  out=$(cd "$3" && AI_KIT_ALLOW_MISSING_TOOLS=1 bash "$KIT/common/gate/gate.sh" --base main 2>&1)
  got=$(printf '%s\n' "$out" | grep -o 'ts(node_modules 없음)' | wc -l | tr -d ' ')
  if [ "$got" = "$2" ]; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1 — 대상이 $2개여야 하는데 ${got}개다:"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1
  fi
}

R=$(mkrepo true svc);      change "$R" svc/index.ts;      expect "ASCII 모듈 루트" 1 "$R"
R=$(mkrepo true 서비스);   change "$R" 서비스/index.ts;   expect "NFC 한글 모듈 루트" 1 "$R"
R=$(mkrepo true 'app[1]'); change "$R" 'app[1]/index.ts'; expect "대괄호 든 모듈 루트" 1 "$R"
R=$(mkrepo true 🚀app);    change "$R" 🚀app/index.ts;    expect "이모지 든 모듈 루트" 1 "$R"
# 대조가 너무 넓어지는 회귀는 여기서만 드러난다. 앞부분 끝의 / 를 빠뜨리면 svc 가
# svc2/ 의 변경에도 맞는다.
R=$(mkrepo true svc svc2); change "$R" svc2/index.ts;     expect "안 바뀐 모듈은 안 잡힌다" 1 "$R"
# 모듈보다 앞에 정렬되는 경로다. 목록이 거기서 잘리면 뒤의 svc 가 빠진다.
R=$(mkrepo true svc);      change "$R" 'docs/🚀-launch.md' svc/index.ts
expect "이모지 경로가 앞에 있는 브랜치의 모듈" 1 "$R"
# 경로 3,000개면 목록이 100KB 를 넘는다. 파이프 버퍼(64KB)를 넉넉히 넘기는 수다.
# 모듈 뒤로 정렬되는 경로에 둔다. 매치 뒤에 남은 목록이 버퍼보다 커야 앞쪽이 죽는다.
R=$(mkrepo true svc); mkdir -p "$R/zz/src/components"
for ((i = 1; i <= 3000; i++)); do : > "$R/zz/src/components/Component$i.tsx"; done
change "$R" svc/index.ts;  expect "파일 3,000개가 같이 바뀐 브랜치의 모듈" 1 "$R"

if [ "$(uname -s)" = Darwin ]; then
  # 서비스 의 NFD — ᄉ ᅥ ᄇ ᅵ ᄉ ᅳ. Finder 같은 도구가 이 모양으로 만든다.
  nfd=$'\xe1\x84\x89\xe1\x85\xa5\xe1\x84\x87\xe1\x85\xb5\xe1\x84\x89\xe1\x85\xb3'
  R=$(mkrepo true "$nfd");  change "$R" "$nfd/index.ts"; expect "NFD 한글 모듈 루트(git 에는 NFC)" 1 "$R"
  R=$(mkrepo false "$nfd"); change "$R" "$nfd/index.ts"; expect "NFD 한글 모듈 루트(git 에도 NFD)" 1 "$R"
else
  echo "  - NFD 한글 모듈 루트 둘 — macOS 에서만 돈다(건너뜀)"
fi

exit $fail
