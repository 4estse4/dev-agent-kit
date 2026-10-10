#!/usr/bin/env bash
# 킷을 설치한 TypeScript 프로젝트에서, 킷이 설치한 파일이 게이트의 prettier 를 통과하는가.
#
# 이 테스트가 있는 이유: package.json 의 format:check 가 `prettier --check .` 이고 prettier 설정이 기본값인 레포에 킷을
# 설치하면, 킷이 놓은 .md · .yml 29개가 prettier 의 포맷에 맞지 않아 게이트(`adapters/ts.sh` 가 실행하는
# `npm run format:check`)가 설치 직후부터 실패했다(이슈 #206). 킷 소유 파일(`.kit/` · `docs/process/` · `.claude/`)은
# 설치기가 루트에 놓는 `.prettierignore` 로 빼고, 프로젝트 소유로 놓는 템플릿은 prettier 기본값으로 포맷해 둔다.
#
# 원격 없는 새 레포에 킷을 설치한다(옵션 없이. 두 사례만 `--lang ts` 와 `--lint` 를 뺀 항목으로). 보는 것:
#   · PATH 의 prettier 가 아래 PIN 과 같다 — 다르면 판정하지 못한 것이라 실패한다. 킷은 TypeScript 도구를 핀하지
#     않으므로(프로젝트의 락파일이 정한다) 이 테스트만의 기준을 여기 둔다. CI 는 이 버전을 설치하고(`kit-tests.yml`),
#     로컬에서는 이 버전을 PATH 앞에 두고 실행한다
#   · 루트 package.json 이 prettier 를 쓰면 `.prettierignore` 가 놓이고, 설치한 그대로 `gate.sh --lint` 의 prettier 가
#     통과한다. node_modules 는 npm install 대신 PATH 의 prettier 를 `.bin/prettier` 로 하나만 둔다
#     그 package.json 은 eslint 도 쓴다 — 킷이 그 옆에 놓는 eslint.config.js 도 prettier 를 통과해야 한다
#   · `--lang ts` 로 설치해도 그렇다. 언어 필터(`common/ci/filter-langs.awk`)가 jvm 의 워크플로 env 블록을 지우면서
#     빈 줄 두 줄을 남겨, 설치된 gates.yml 이 prettier 에서 실패했다
#   · `--lint` 없이 `--hooks --agent --templates --ci` 로 설치해도 그렇다. `.prettierignore` 가 빼는 경로를 놓는 것은 그
#     항목들인데, `.prettierignore` 가 `--lint` 에서만 놓여 게이트가 실패했다
#   · go.mod 가 하위 디렉터리에 있으면 킷이 그 옆에 놓는 .golangci.yml 도 루트의 `prettier --check .` 를 통과한다.
#     게이트는 Go 도구까지 실행하므로 이 사례만 게이트 대신 format:check 와 같은 명령을 실행한다
#   · 루트 package.json 이 prettier 를 쓰지 않으면 `.prettierignore` 를 놓지 않는다. 하위 디렉터리의 package.json 만
#     prettier 를 써도 놓지 않는다 — prettier 는 실행한 디렉터리의 `.prettierignore` 만 읽고, 거기서 실행한 prettier 는
#     루트의 킷 파일을 보지 않는다
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
USES='{"name":"demo","private":true,"scripts":{"format:check":"prettier --check ."},"devDependencies":{"eslint":"10.0.0","prettier":"'"$PIN"'"}}'
demo() { # $1=이름 $2=package.json 내용 $3=미리 둘 .prettierignore 내용(없으면 빈 값) $4=커밋 전에 부를 함수(없으면 빈 값) 나머지=설치 옵션 → 설치한 레포를 R 에 둔다
  local name="$1" pkg="$2" ignore="$3" extra="$4"; shift 4
  R="$T/$name"; mkdir -p "$R"; git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
  printf '%s\n' "$pkg" > "$R/package.json"
  printf 'export const x = 1;\n' > "$R/index.ts"
  [ -z "$ignore" ] || printf '%s\n' "$ignore" > "$R/.prettierignore"
  [ -z "$extra" ] || "$extra"
  (cd "$R" && prettier --write package.json index.ts > /dev/null)
  git -C "$R" add -A && git -C "$R" commit -q -m init
  if ! bash "$KIT/install.sh" "$R" "$@" > "$T/$name-install.log" 2>&1; then
    echo "  ✗ $name: 설치가 실패했다"; tail -5 "$T/$name-install.log" | sed 's/^/      /'; fail=1; return 1
  fi
}

web_uses_prettier() { mkdir -p "$R/web" && printf '%s\n' "$USES" > "$R/web/package.json"; }
backend_go() { mkdir -p "$R/backend" && printf 'module example.com/backend\n\ngo 1.25\n' > "$R/backend/go.mod"; }

gate_prettier() { # $1=이름. R 의 레포에서 게이트의 prettier 가 통과하는지 본다
  mkdir -p "$R/node_modules/.bin" && ln -s "$(command -v prettier)" "$R/node_modules/.bin/prettier"
  out=$(cd "$R" && bash .kit/gate/gate.sh --lint 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^gate ✓.*prettier'; then
    echo "  ✓ $1: 게이트의 prettier 가 통과한다(prettier $PIN)"
  else
    echo "  ✗ $1: 게이트의 prettier 가 통과하지 못했다(rc=$rc, prettier $PIN):"
    printf '%s\n' "$out" | grep -E '^gate |^──── |^\[warn\] ' | sed 's/^/      /'
    fail=1
  fi
}

# prettier 를 쓰는 레포: .prettierignore 가 놓이고 게이트의 prettier 가 통과한다
if demo uses "$USES" "" ""; then
  if [ -f "$R/.prettierignore" ] && [ -f "$R/eslint.config.js" ]; then echo "  ✓ uses: 루트에 .prettierignore 와 eslint.config.js 가 놓였다"
  else echo "  ✗ uses: 루트에 .prettierignore 나 eslint.config.js 가 놓이지 않았다"; fail=1; fi
  gate_prettier uses
fi

# TypeScript 만 골라 설치한 레포: 언어 필터를 거친 gates.yml 도 게이트의 prettier 를 통과한다
demo tsonly "$USES" "" "" --lang ts && gate_prettier tsonly

# 린터 설정 없이 설치한 레포: .prettierignore 가 빼는 경로는 --hooks · --agent · --templates 가 놓으므로 그때도 놓인다
if demo nolint "$USES" "" "" --hooks --agent --templates --ci; then
  if [ -f "$R/.prettierignore" ]; then echo "  ✓ nolint: --lint 없이 설치해도 루트에 .prettierignore 가 놓였다"
  else echo "  ✗ nolint: --lint 없이 설치하자 .prettierignore 가 놓이지 않았다"; fail=1; fi
  gate_prettier nolint
fi

# go.mod 가 하위 디렉터리에 있는 레포: 그 옆에 놓인 .golangci.yml 도 루트의 prettier 를 통과한다
if demo gomod "$USES" "" backend_go; then
  if [ ! -f "$R/backend/.golangci.yml" ]; then echo "  ✗ gomod: backend/.golangci.yml 이 놓이지 않았다"; fail=1
  elif out=$(cd "$R" && prettier --check . 2>&1); then echo "  ✓ gomod: backend/.golangci.yml 이 놓이고 루트의 prettier --check . 가 통과한다(prettier $PIN)"
  else
    echo "  ✗ gomod: 루트의 prettier --check . 가 통과하지 못했다(prettier $PIN):"
    printf '%s\n' "$out" | grep '^\[warn\] ' | sed 's/^/      /'; fail=1
  fi
fi

# prettier 를 쓰지 않는 레포: .prettierignore 를 놓지 않는다
NOPRETTIER='{"name":"demo","private":true,"scripts":{"build":"tsc"}}'
if demo noprettier "$NOPRETTIER" "" ""; then
  if [ ! -e "$R/.prettierignore" ] && [ ! -e "$R/.prettierignore.kit-new" ]; then
    echo "  ✓ noprettier: .prettierignore 를 놓지 않았다"
  else echo "  ✗ noprettier: prettier 를 쓰지 않는데 .prettierignore 가 놓였다"; fail=1; fi
fi

# 하위 디렉터리의 package.json 만 prettier 를 쓰는 레포: 어느 자리에도 놓지 않는다
if demo sub "$NOPRETTIER" "" web_uses_prettier; then
  if [ ! -e "$R/.prettierignore" ] && [ ! -e "$R/web/.prettierignore" ]; then
    echo "  ✓ sub: 하위 디렉터리의 package.json 만 prettier 를 쓰면 .prettierignore 를 놓지 않았다"
  else echo "  ✗ sub: 하위 디렉터리의 package.json 만 prettier 를 쓰는데 .prettierignore 가 놓였다"; fail=1; fi
fi

# .prettierignore 가 이미 있는 레포: 그것을 두고 킷의 것을 옆에 놓는다
if demo existing "$USES" "dist/" ""; then
  if [ "$(cat "$R/.prettierignore")" = "dist/" ] && [ -f "$R/.prettierignore.kit-new" ]; then
    echo "  ✓ existing: 프로젝트의 .prettierignore 를 두고 .prettierignore.kit-new 를 옆에 놓았다"
  else echo "  ✗ existing: 프로젝트의 .prettierignore 가 바뀌었거나 .prettierignore.kit-new 가 없다"; fail=1; fi
fi

rm -rf "$T"
exit $fail
