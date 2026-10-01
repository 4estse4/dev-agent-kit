#!/usr/bin/env bash
# 설치기는 eslint 를 쓰는 package.json 옆에만, 그 파일이 쓸 eslint 설정이 따로 없을 때만 eslint.config.js 를 놓는다.
#
# 이 테스트가 있는 이유: 설치기가 package.json 옆마다 킷의 eslint.config.js 를 놓았다(이슈 #172).
# oxlint 를 쓰는 앱에서는 그 설정을 읽는 도구가 없고, 템플릿 주석은 「어기면 게이트가 실패한다」고 적는다.
# 더 나쁜 경우도 있다 — ESLint 는 eslint.config.js 를 .mjs · .cjs · .ts 보다 먼저 고르고, 파일의 디렉터리부터
# 조상 디렉터리로 올라가며 설정을 찾는다. 그래서 옆에 놓은 킷의 설정이 같은 디렉터리나 워크스페이스 루트의
# 프로젝트 설정 대신 읽힌다(PR #184 1라운드 콜드 리뷰가 eslint 9 · 8 로 재현했다).
#
# 깨끗한 레포에 package.json 의 모양이 다른 디렉터리를 두고 `install.sh --lint` 를 실행한다. 보는 것:
#   · package.json 에 `"eslint":` 키가 있거나(대개 의존성이다) eslint 를 부르는 lint 스크립트가 있으면 놓는다
#   · 그 표시가 없으면 놓지 않는다 — 다른 린터를 쓰는 앱, 이름에 eslint 가 든 패키지만 남은 앱, 린터가 없는 앱
#   · 그 디렉터리나 조상 디렉터리(레포 루트까지)에 프로젝트의 eslint 설정(eslint.config.* · .eslintrc* ·
#     package.json 의 eslintConfig)이 있으면 놓지 않는다. 조상의 eslint.config.js 가 킷의 것과 내용이 같으면
#     프로젝트 설정으로 세지 않는다
#   · `--dry-run` 이 예고하는 자리와 실제로 놓인 자리가 같다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
T=$(mktemp -d)

new_repo() { # $1=레포 이름 → 그 경로를 R 에 둔다
  R="$T/$1"; mkdir -p "$R"; git init -q -b main "$R"
  git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
}
mk() { # $1=디렉터리(레포 루트는 .) $2=package.json 내용 $3=함께 둘 파일(선택)
  mkdir -p "$R/$1"; [ -z "$2" ] || printf '%s\n' "$2" > "$R/$1/package.json"
  [ -z "${3:-}" ] || : > "$R/$1/$3"
}
check() { # $1=놓여야 할 디렉터리들 $2=놓이지 않아야 할 디렉터리들. 레포 루트는 . 로 적는다
  local dry d want got pred f
  git -C "$R" add -A && git -C "$R" commit -q -m init
  dry=$(bash "$KIT/install.sh" "$R" --lint --dry-run 2>&1) || { echo "  ✗ $(basename "$R"): --dry-run 이 실패했다"; fail=1; return; }
  bash "$KIT/install.sh" "$R" --lint > "$T/install.log" 2>&1 || { echo "  ✗ $(basename "$R"): 설치가 실패했다"; tail -5 "$T/install.log" | sed 's/^/      /'; fail=1; return; }
  for d in $1 $2; do
    case " $1 " in *" $d "*) want=놓음 ;; *) want="안 놓음" ;; esac
    f="eslint.config.js"; [ "$d" = . ] || f="$d/eslint.config.js"
    [ -f "$R/$f" ] && got=놓음 || got="안 놓음"
    printf '%s\n' "$dry" | grep -qxE "[[:space:]]*\+ ${f//./\\.}" && pred=놓음 || pred="안 놓음"
    if [ "$got" = "$want" ] && [ "$pred" = "$want" ]; then echo "  ✓ $(basename "$R") $d → $want (예고도 같다)"
    else echo "  ✗ $(basename "$R") $d → 실제 $got · 예고 $pred, $want 이어야 한다"; fail=1; fi
  done
}

# 한 레포에 서로 무관한 앱들. 레포 루트에는 package.json 이 없다.
new_repo apps
mk dep          '{ "name": "a", "devDependencies": { "eslint": "^9.0.0" } }'
mk script       '{ "name": "b", "scripts": { "lint": "eslint ." } }'
mk oxlint       '{ "name": "c", "scripts": { "lint": "oxlint src" }, "devDependencies": { "oxlint": "^1.0.0", "eslint-plugin-react": "^7.0.0", "@typescript-eslint/parser": "^8.0.0" } }'
mk none         '{ "name": "d", "scripts": { "build": "tsc" } }'
mk mjs          '{ "name": "e", "devDependencies": { "eslint": "^9.0.0" } }' eslint.config.mjs
mk eslintrc     '{ "name": "f", "devDependencies": { "eslint": "^8.57.0" } }' .eslintrc.json
mk pkgconfig    '{ "name": "g", "devDependencies": { "eslint": "^8.57.0" }, "eslintConfig": { "root": true } }'
check "dep script" "oxlint none mjs eslintrc pkgconfig"

# 워크스페이스: 루트의 eslint.config.mjs 를 패키지가 쓴다(eslint 9).
new_repo ws-flat
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^9.0.0" } }' eslint.config.mjs
mk packages/a   '{ "name": "a", "scripts": { "lint": "eslint ." } }'
check "" ". packages/a"

# 워크스페이스: 루트의 .eslintrc.json 을 패키지가 쓴다(eslint 8).
new_repo ws-legacy
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^8.57.0" } }' .eslintrc.json
mk packages/b   '{ "name": "b", "scripts": { "lint": "eslint ." } }'
check "" ". packages/b"

# 워크스페이스: 루트에 eslint 의존성만 있고 설정이 없으면 루트와 패키지 양쪽에 놓는다. 킷 설정의 ignores · files
# 글롭(dist/** · vite.config.* 등)은 그 설정 파일의 디렉터리를 기준으로 읽히므로, 루트에만 놓으면 패키지의 파일에
# 맞지 않아 게이트가 실패한다(PR #184 2라운드 콜드 리뷰가 eslint 9 로 재현했다). find 가 루트를 먼저 내놓으면 실제
# 설치는 패키지를 볼 때 방금 루트에 쓴 킷 설정을 만난다 — 그것을 프로젝트 설정으로 세면 예고와 실제가 어긋난다.
new_repo ws-kit
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^9.0.0" } }'
mk packages/c   '{ "name": "c", "scripts": { "lint": "eslint ." } }'
check ". packages/c" ""

# 워크스페이스: 루트에 킷과 같은 eslint.config.js 가 이미 있다(이전 설치). find 순서와 상관없이 루트의 킷 설정을 만나는
# 경우다 — 프로젝트 설정으로 세지 않고 패키지에 놓는다.
new_repo ws-rekit
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^9.0.0" } }'
cp "$KIT/common/lint/ts/eslint.config.js" "$R/eslint.config.js"
mk packages/c   '{ "name": "c", "scripts": { "lint": "eslint ." } }'
check "packages/c" ""

# 워크스페이스: 루트에 프로젝트가 쓴 eslint.config.js(킷의 것과 내용이 다르다)가 있으면 패키지에 놓지 않는다.
new_repo ws-js
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^9.0.0" } }'
printf '%s\n' 'export default [];' > "$R/eslint.config.js"
mk packages/d   '{ "name": "d", "scripts": { "lint": "eslint ." } }'
check "" "packages/d"

# 워크스페이스: 루트 package.json 의 eslintConfig 를 패키지가 쓴다(eslint 8).
new_repo ws-pkgconfig
mk .            '{ "name": "root", "private": true, "workspaces": ["packages/*"], "devDependencies": { "eslint": "^8.57.0" }, "eslintConfig": { "root": true } }'
mk packages/e   '{ "name": "e", "scripts": { "lint": "eslint ." } }'
check "" ". packages/e"

rm -rf "$T"
exit $fail
