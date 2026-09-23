#!/usr/bin/env bash
# 게이트가 바뀐 모듈을 검사 대상으로 고르는가 — 모듈 루트의 이름이 평범하지 않을 때.
#
# 이 테스트가 있는 이유: gate.sh 는 find 가 낸 모듈 경로를 git 이 낸 변경 경로와 대조해
# 대상을 고른다. 그 대조가 세 가지로 어긋났다.
#   · 모듈 경로를 정규식으로 썼다. `app[1]` 같은 루트는 자기 안의 파일과 안 맞았다
#   · macOS 에서 디스크의 이름은 NFD(자모)인데 git 에는 NFC(음절)로 기록되면 바이트가 달랐다
#   · 변경 목록을 `printf | grep -q` 로 넘겼다. pipefail 아래에서 grep 이 첫 매치에서 끝나면
#     남은 목록을 쓰던 printf 가 SIGPIPE 로 죽어 매치가 거짓이 됐다. 변경 목록이 파이프
#     버퍼보다 긴 브랜치에서 앞쪽에 정렬되는 모듈이 빠졌다
# 셋 다 "검사 대상 없음" 에 rc=0 이었다. 게이트는 통과라고 말하는데 그 모듈을 안 봤다.
#
# 게이트를 실제로 돌린다. package.json 만 두고 node_modules 는 두지 않으므로, 대상으로
# 잡히면 ts 어댑터가 `ts(node_modules 없음)` 을 건너뜀으로 찍는다. 그 줄이 "잡혔다" 는 뜻이다.
# NFD 경우는 macOS 에서만 돈다. 리눅스의 git 은 디스크의 바이트를 그대로 기록하므로 둘이
# 어긋나지 않는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

check() { # $1=설명  $2=디스크에 만들 모듈 루트 이름  $3=같이 바꿀 다른 파일 수(기본 0)
           # $4=커밋할 때의 core.precomposeUnicode(기본 true)
  local what="$1" root="$2" extra="${3:-0}" pc="${4:-true}" R out i
  R=$(mktemp -d)/repo; mkdir -p "$R/$root"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  # true 는 macOS 의 git init 이 켜는 값이다. 이 값으로 커밋하면 NFD 이름이 NFC 로 기록되고,
  # false 면 NFD 그대로 기록된다.
  git -C "$R" config core.precomposeUnicode "$pc"
  printf '{"name":"m","private":true}\n' > "$R/$root/package.json"
  printf 'export const a = 1;\n' > "$R/$root/index.ts"
  git -C "$R" add -A; git -C "$R" commit -qm init
  git -C "$R" switch -qc change
  printf 'export const a = 2;\n' > "$R/$root/index.ts"
  # 모듈 뒤로 정렬되는 경로에 둔다. 매치 뒤에 남은 목록이 파이프 버퍼보다 커야 앞쪽이 죽는다.
  if [ "$extra" -gt 0 ]; then
    mkdir -p "$R/zz/src/components"
    for ((i = 1; i <= extra; i++)); do : > "$R/zz/src/components/Component$i.tsx"; done
  fi
  git -C "$R" add -A; git -C "$R" commit -qm change
  out=$(cd "$R" && AI_KIT_ALLOW_MISSING_TOOLS=1 bash "$KIT/common/gate/gate.sh" --base main 2>&1)
  if printf '%s\n' "$out" | grep -q 'ts(node_modules 없음)'; then
    echo "  ✓ $what"
  else
    echo "  ✗ $what — 바뀐 모듈이 검사 대상으로 안 잡혔다:"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1
  fi
}

check "ASCII 모듈 루트"      "svc"
check "NFC 한글 모듈 루트"   "서비스"
check "대괄호 든 모듈 루트"  "app[1]"
# 경로 3,000개면 목록이 100KB 를 넘는다. 파이프 버퍼(64KB)를 넉넉히 넘기는 수다.
check "파일 3,000개가 같이 바뀐 브랜치의 모듈" "svc" 3000
if [ "$(uname -s)" = Darwin ]; then
  # 서비스 의 NFD — ᄉ ᅥ ᄇ ᅵ ᄉ ᅳ. Finder 같은 도구가 이 모양으로 만든다.
  nfd=$'\xe1\x84\x89\xe1\x85\xa5\xe1\x84\x87\xe1\x85\xb5\xe1\x84\x89\xe1\x85\xb3'
  check "NFD 한글 모듈 루트(git 에는 NFC)" "$nfd"
  # 원래 되던 경우다. 모듈 쪽만 NFC 로 맞추고 변경 목록 쪽을 안 맞추면 여기가 깨진다.
  check "NFD 한글 모듈 루트(git 에도 NFD)" "$nfd" 0 false
else
  echo "  - NFD 한글 모듈 루트 둘 — macOS 에서만 돈다(건너뜀)"
fi

exit $fail
