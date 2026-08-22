#!/usr/bin/env bash
# Go 게이트. CWD = go.mod가 있는 디렉터리. lib.sh는 이미 source됨.
gate_have go || { gate_skip "go(미설치)"; return 0 2>/dev/null || exit 0; }

gate_run_empty "gofmt"        gofmt -l .
gate_have goimports && gate_run_empty "goimports" goimports -l . || gate_skip "goimports"
gate_run       "go vet"       go vet ./...
gate_have golangci-lint && gate_run "golangci-lint" golangci-lint run || gate_skip "golangci-lint"
# 프로젝트가 추가 플래그를 요구할 수 있다(예: 공유 DB 를 쓰는 통합 테스트에
# 필요한 -p 1 직렬화). 게이트 정의를 포크하지 않고 여기로 주입한다.
# shellcheck disable=SC2086
gate_run       "go test"      go test ${AI_KIT_GO_TEST_FLAGS:-} ./...
