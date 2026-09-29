#!/usr/bin/env bash
# Go 게이트. CWD = go.mod가 있는 디렉터리. lib.sh는 이미 source됨.
gate_have go || { gate_skip "go(미설치)"; return 0 2>/dev/null || exit 0; }

gate_run_empty "gofmt"        gofmt -l .
# go.mod 가 tool 로 선언했으면 그 버전을, 아니면 PATH 의 것을 쓴다.
# 선언해두면 로컬과 CI 가 같은 버전이 되고, 도구가 없어 이 검사가 실행되지 않는 일이 없어진다:
#   go get -tool golang.org/x/tools/cmd/goimports@<버전>
if _gi=$(gate_go_tool goimports); then
  # shellcheck disable=SC2086
  gate_run_empty "goimports" $_gi -l .
  unset _gi
else
  gate_skip "goimports"
fi
gate_run       "go vet"       go vet ./...
gate_have golangci-lint && gate_run "golangci-lint" golangci-lint run || gate_skip "golangci-lint"
# --lint 모드에서는 테스트를 실행하지 않는다. 커밋마다 테스트를 실행하면 커밋이 비싸지고,
# 비싼 훅은 --no-verify 습관을 만든다 — 끄는 게이트는 없는 게이트다.
if [ "${GATE_LINT_ONLY:-0}" != 1 ]; then
# 프로젝트가 추가 플래그를 요구할 수 있다(예: 공유 DB 를 쓰는 통합 테스트에
# 필요한 -p 1 직렬화). 게이트 정의를 복사해 고치지 않고 AI_KIT_GO_TEST_FLAGS 로 전달한다.
# shellcheck disable=SC2086
gate_run       "go test"      go test ${AI_KIT_GO_TEST_FLAGS:-} ./...
fi
