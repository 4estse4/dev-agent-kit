#!/usr/bin/env bash
# 킷을 설치한 TypeScript 프로젝트에서, 킷이 설치한 파일이 게이트의 prettier 를 통과하는가.
#
# 이 테스트가 있는 이유: package.json 의 format:check 가 `prettier --check .` 이고 prettier 설정이 기본값인 레포에 킷을
# 설치하면, 킷이 놓은 .md · .yml 29개가 prettier 의 포맷에 맞지 않아 게이트(`adapters/ts.sh` 가 실행하는
# `npm run format:check`)가 설치 직후부터 실패했다(이슈 #206). 킷 소유 파일(`.kit/` · `docs/process/` · `.claude/`)은
# 설치기가 루트에 놓는 `.prettierignore` 로 빼고, 프로젝트 소유로 놓는 템플릿은 prettier 기본값으로 포맷해 둔다.
#
# 원격 없는 새 레포에 킷을 옵션 없이 설치한다. 보는 것:
#   · PATH 의 prettier 가 아래 PIN 과 같다 — 다르면 판정하지 못한 것이라 실패한다. 킷은 TypeScript 도구를 핀하지
#     않으므로(프로젝트의 락파일이 정한다) 이 테스트만의 기준을 여기 둔다. CI 는 이 버전을 설치하고(`kit-tests.yml`),
#     로컬에서는 이 버전을 PATH 앞에 두고 실행한다
#   · 루트 package.json 이 prettier 를 쓰면 `.prettierignore` 가 놓이고, 설치한 그대로 `gate.sh --lint` 의 prettier 가
#     통과한다. node_modules 는 npm install 대신 PATH 의 prettier 를 `.bin/prettier` 로 하나만 둔다
#   · 루트 package.json 이 prettier 를 쓰지 않으면 `.prettierignore` 를 놓지 않는다
#   · 프로젝트에 `.prettierignore` 가 이미 있으면 그것을 두고 킷의 것을 `.prettierignore.kit-new` 로 옆에 놓는다
set -u
PIN=3.9.9
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

got=$(prettier --version 2>/dev/null)
if [ "$got" != "$PIN" ]; then
  echo "  ✗ PATH 의 prettier 가 핀 버전이 아니다(핀 $PIN · PATH ${got:-없음}) — 판정하지 못했다."
  echo "    핀 버전을 받아 PATH 앞에 두고 다시 실행한다. 버전은 이 테스트의 PIN 이다."
  exit 1
fi

T=$(mktemp -d)
USES='{"name":"demo","private":true,"scripts":{"format:check":"prettier --check ."},"devDependencies":{"prettier":"'"$PIN"'"}}'
demo() { # $1=이름 $2=package.json 내용 $3=미리 둘 .prettierignore 내용(없으면 빈 값) → 설치한 레포를 R 에 둔다
  R="$T/$1"; mkdir -p "$R"; git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  printf '%s\n' "$2" > "$R/package.json"
  printf 'export const x = 1;\n' > "$R/index.ts"
  [ -z "$3" ] || printf '%s\n' "$3" > "$R/.prettierignore"
  (cd "$R" && prettier --write package.json index.ts > /dev/null)
  git -C "$R" add -A && git -C "$R" commit -q -m init
  if ! bash "$KIT/install.sh" "$R" > "$T/$1-install.log" 2>&1; then
    echo "  ✗ $1: 설치가 실패했다"; tail -5 "$T/$1-install.log" | sed 's/^/      /'; fail=1; return 1
  fi
}

# prettier 를 쓰는 레포: .prettierignore 가 놓이고 게이트의 prettier 가 통과한다
if demo uses "$USES" ""; then
  if [ -f "$R/.prettierignore" ]; then echo "  ✓ uses: 루트에 .prettierignore 가 놓였다"
  else echo "  ✗ uses: 루트에 .prettierignore 가 놓이지 않았다"; fail=1; fi
  mkdir -p "$R/node_modules/.bin" && ln -s "$(command -v prettier)" "$R/node_modules/.bin/prettier"
  out=$(cd "$R" && bash .kit/gate/gate.sh --lint 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^gate ✓.*prettier'; then
    echo "  ✓ uses: 게이트의 prettier 가 통과한다(prettier $PIN)"
  else
    echo "  ✗ uses: 게이트의 prettier 가 통과하지 못했다(rc=$rc, prettier $PIN):"
    printf '%s\n' "$out" | grep -E '^gate |^──── |^\[warn\] ' | sed 's/^/      /'
    fail=1
  fi
fi

# prettier 를 쓰지 않는 레포: .prettierignore 를 놓지 않는다
if demo noprettier '{"name":"demo","private":true,"scripts":{"build":"tsc"}}' ""; then
  if [ ! -e "$R/.prettierignore" ] && [ ! -e "$R/.prettierignore.kit-new" ]; then
    echo "  ✓ noprettier: .prettierignore 를 놓지 않았다"
  else echo "  ✗ noprettier: prettier 를 쓰지 않는데 .prettierignore 가 놓였다"; fail=1; fi
fi

# .prettierignore 가 이미 있는 레포: 그것을 두고 킷의 것을 옆에 놓는다
if demo existing "$USES" "dist/"; then
  if [ "$(cat "$R/.prettierignore")" = "dist/" ] && [ -f "$R/.prettierignore.kit-new" ]; then
    echo "  ✓ existing: 프로젝트의 .prettierignore 를 두고 .prettierignore.kit-new 를 옆에 놓았다"
  else echo "  ✗ existing: 프로젝트의 .prettierignore 가 바뀌었거나 .prettierignore.kit-new 가 없다"; fail=1; fi
fi

rm -rf "$T"
exit $fail
