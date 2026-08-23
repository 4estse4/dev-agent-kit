#!/usr/bin/env bash
# TypeScript/JS 게이트. CWD = package.json이 있는 디렉터리.
[ -d node_modules ] || { gate_skip "ts(node_modules 없음)"; return 0 2>/dev/null || exit 0; }

# package.json의 named script를 단일 출처로 쓴다 — 로컬·CI가 같은 명령을 돈다.
has_script() { node -e "process.exit(require('./package.json').scripts?.['$1']?0:1)" 2>/dev/null; }

has_script format:check && gate_run "prettier" npm run --silent format:check || gate_skip "prettier"
has_script lint         && gate_run "eslint"   npm run --silent lint          || gate_skip "eslint"
has_script typecheck    && gate_run "tsc"      npm run --silent typecheck     || gate_skip "tsc"
if [ "${GATE_LINT_ONLY:-0}" != 1 ]; then
has_script test         && gate_run "vitest"   npm test --silent             || gate_skip "test"
# 프로덕션 빌드까지 돌린다. tsc --noEmit 가 통과해도 번들러는 죽을 수 있다
# (미해결 런타임 import·에셋 경로·플러그인 설정). 배포 산출물을 만드는 경로를
# 게이트가 한 번도 실행하지 않으면 "기동된다"는 주장을 지탱할 수 없다.
has_script build        && gate_run "build"    npm run --silent build        || gate_skip "build"
fi
