#!/usr/bin/env bash
# TypeScript/JS 게이트. CWD = package.json이 있는 디렉터리.
[ -d node_modules ] || { gate_skip "ts(node_modules 없음)"; return 0 2>/dev/null || exit 0; }

# package.json의 named script를 단일 출처로 쓴다 — 로컬·CI가 같은 명령을 돈다.
has_script() { node -e "process.exit(require('./package.json').scripts?.['$1']?0:1)" 2>/dev/null; }

has_script format:check && gate_run "prettier" npm run --silent format:check || gate_skip "prettier"
has_script lint         && gate_run "eslint"   npm run --silent lint          || gate_skip "eslint"
has_script typecheck    && gate_run "tsc"      npm run --silent typecheck     || gate_skip "tsc"
has_script test         && gate_run "vitest"   npm test --silent             || gate_skip "test"
