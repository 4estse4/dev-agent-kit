#!/usr/bin/env bash
# 스크립트가 선언돼 있지 않은 것은 gate_absent 로 보고한다 — 도구 부재(gate_skip)와
# 다르다. 전자는 프로젝트 구성이고 후자는 환경 문제다. 섞으면 평범한 JS 프로젝트가
# 쓰지도 않는 단계를 만들어야 커밋할 수 있게 된다.
# TypeScript/JS 게이트. CWD = package.json이 있는 디렉터리.
[ -d node_modules ] || { gate_skip "ts(node_modules 없음)"; return 0 2>/dev/null || exit 0; }

# package.json의 named script를 단일 출처로 쓴다 — 로컬·CI가 같은 명령을 실행한다.
has_script() { node -e "process.exit(require('./package.json').scripts?.['$1']?0:1)" 2>/dev/null; }

has_script format:check && gate_run "prettier" npm run --silent format:check || gate_absent "format:check"
# 라벨을 `eslint` 로 박지 않는다 — 이 단계는 `lint` 스크립트가 무엇이든 그것을 실행한다.
# oxlint·biome 를 쓰는 프로젝트에서 출력이 "eslint 통과" 라고 말하면 그건 거짓이다.
has_script lint         && gate_run "lint"     npm run --silent lint          || gate_absent "lint"
has_script typecheck    && gate_run "tsc"      npm run --silent typecheck     || gate_absent "typecheck"
if [ "${GATE_LINT_ONLY:-0}" != 1 ]; then
has_script test         && gate_run "vitest"   npm test --silent             || gate_absent "test"
# 프로덕션 빌드까지 실행한다. tsc --noEmit 가 통과해도 번들러는 죽을 수 있다
# (미해결 런타임 import·에셋 경로·플러그인 설정). 배포 산출물을 만드는 경로를
# 게이트가 한 번도 실행하지 않으면 "기동된다"는 주장을 지탱할 수 없다.
has_script build        && gate_run "build"    npm run --silent build        || gate_absent "build"
fi
