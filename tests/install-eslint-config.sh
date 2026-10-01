#!/usr/bin/env bash
# 설치기는 eslint 를 쓰는 package.json 옆에만 eslint.config.js 를 놓는다.
#
# 이 테스트가 있는 이유: 설치기가 package.json 옆마다 킷의 eslint.config.js 를 놓았다(이슈 #172).
# oxlint 를 쓰는 앱에는 그 설정을 실행하는 것이 없고, 템플릿 주석은 「어기면 게이트가 실패한다」고 적는다.
# 더 나쁜 경우도 있다 — ESLint 는 eslint.config.js 를 .mjs · .cjs · .ts 보다 먼저 고르므로, 프로젝트가
# eslint.config.mjs 를 쓰는데 옆에 킷의 eslint.config.js 를 놓으면 킷의 설정이 프로젝트 설정 대신 읽힌다.
#
# 깨끗한 레포에 package.json 의 모양이 다른 디렉터리를 두고 `install.sh --lint` 를 실행한다. 보는 것:
#   · eslint 를 쓰는 표시(dependencies · devDependencies 의 eslint, eslint 를 부르는 lint 스크립트)가 있으면 놓는다
#   · 그 표시가 없으면(다른 린터 · 린터 없음) 놓지 않는다
#   · 다른 이름의 eslint 설정(eslint.config.mjs · .eslintrc.json · package.json 의 eslintConfig)이 있으면 놓지 않는다
#   · `--dry-run` 이 예고하는 자리와 실제로 놓인 자리가 같다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T

# 디렉터리 이름 → 기대(놓음 · 안 놓음)와 package.json · 함께 둘 파일
mk() { # $1=디렉터리 $2=package.json 내용 $3=함께 둘 파일(선택)
  mkdir -p "$R/$1"; printf '%s\n' "$2" > "$R/$1/package.json"
  [ -z "${3:-}" ] || : > "$R/$1/$3"
}
mk dep          '{ "name": "a", "devDependencies": { "eslint": "^9.0.0" } }'
mk script       '{ "name": "b", "scripts": { "lint": "eslint ." } }'
mk oxlint       '{ "name": "c", "scripts": { "lint": "oxlint src" }, "devDependencies": { "oxlint": "^1.0.0" } }'
mk none         '{ "name": "d", "scripts": { "build": "tsc" } }'
mk mjs          '{ "name": "e", "devDependencies": { "eslint": "^9.0.0" } }' eslint.config.mjs
mk eslintrc     '{ "name": "f", "devDependencies": { "eslint": "^8.57.0" } }' .eslintrc.json
mk pkgconfig    '{ "name": "g", "devDependencies": { "eslint": "^8.57.0" }, "eslintConfig": { "root": true } }'
git -C "$R" add -A && git -C "$R" commit -q -m init

want_placed="dep script"
want_absent="oxlint none mjs eslintrc pkgconfig"

dry=$(bash "$KIT/install.sh" "$R" --lint --dry-run 2>&1) || { echo "  ✗ --dry-run 이 실패했다:"; printf '%s\n' "$dry" | tail -5 | sed 's/^/      /'; exit 1; }
bash "$KIT/install.sh" "$R" --lint > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }

for d in $want_placed $want_absent; do
  case " $want_placed " in *" $d "*) want=놓음 ;; *) want="안 놓음" ;; esac
  [ -f "$R/$d/eslint.config.js" ] && got=놓음 || got="안 놓음"
  printf '%s\n' "$dry" | grep -qE "^[[:space:]]*\+ $d/eslint\.config\.js$" && pred=놓음 || pred="안 놓음"
  if [ "$got" = "$want" ] && [ "$pred" = "$want" ]; then echo "  ✓ $d → $want (예고도 같다)"
  else echo "  ✗ $d → 실제 $got · 예고 $pred, $want 이어야 한다"; fail=1; fi
done

rm -rf "$T"
exit $fail
