#!/usr/bin/env bash
# pre-commit 이 스테이지된 파일의 충돌 마커를 막는가 — 파일이 클 때.
#
# 이 테스트가 있는 이유: 훅은 `git show ":$f" | grep -q` 로 마커를 찾았고 set -o pipefail 이다.
# grep 이 첫 매치에서 끝나면 남은 내용을 쓰던 git show 가 SIGPIPE 로 죽고, pipefail 이 그것을
# 파이프라인의 결과로 삼아 "마커 없음" 이 됐다. 마커가 앞쪽에 있고 뒤가 파이프 버퍼보다 긴
# 파일 — 병합 충돌이 가장 흔한 package-lock.json 이 그 모양이다 — 이 rc=0 으로 커밋됐다.
#
# 훅을 실제로 실행한다. 설치된 레포의 .ai-kit/ 대신 킷의 common/ 을 AI_KIT_DIR 로 준다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

check() { # $1=설명  $2=마커 뒤에 붙일 줄 수
  local what="$1" lines="$2" R out rc
  R=$(mktemp -d)/repo; mkdir -p "$R"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  echo x > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm init
  git -C "$R" switch -qc feature      # 보호 브랜치 규칙에 먼저 걸리지 않게
  { printf '<<<<<<< HEAD\n  "a": 1,\n=======\n  "a": 2,\n>>>>>>> other\n'
    [ "$lines" -gt 0 ] && seq -f '  "pkg-%g": "1.0.0",' 1 "$lines"
  } > "$R/package-lock.json"
  git -C "$R" add package-lock.json
  out=$(cd "$R" && AI_KIT_DIR="$KIT/common" AI_KIT_ALLOW_MISSING_TOOLS=1 bash "$KIT/common/git-hooks/pre-commit" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '병합 충돌 마커'; then
    echo "  ✓ $what"
  else
    echo "  ✗ $what — 충돌 마커가 든 파일을 통과시켰다(rc=$rc):"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1
  fi
}

check "작은 파일의 충돌 마커" 0
# 8,000줄이면 180KB 쯤이다. 파이프 버퍼(64KB)를 넉넉히 넘기는 크기다.
check "큰 파일 앞쪽의 충돌 마커" 8000

exit $fail
