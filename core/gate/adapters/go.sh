#!/usr/bin/env bash
# Go 게이트. CWD = go.mod가 있는 디렉터리. lib.sh는 이미 source됨.
gate_have go || { gate_skip "go(미설치)"; return 0 2>/dev/null || exit 0; }

gate_run_empty "gofmt"        gofmt -l .
gate_have goimports && gate_run_empty "goimports" goimports -l . || gate_skip "goimports"
gate_run       "go vet"       go vet ./...
gate_have golangci-lint && gate_run "golangci-lint" golangci-lint run || gate_skip "golangci-lint"
gate_run       "go test"      go test ./...
