#!/usr/bin/env bash
# PostToolUse: 편집한 파일을 자동 포맷한다.
# 포맷만 한다 — 진단은 LSP, 전체 게이트는 git 훅과 CI 가 맡는다.
# 절대 차단하지 않는다. 필요: jq
input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

case "$file" in
  *.go)
    command -v gofmt     >/dev/null 2>&1 && gofmt -w "$file" 2>/dev/null
    command -v goimports >/dev/null 2>&1 && goimports -w "$file" 2>/dev/null
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.css|*.scss|*.json|*.md|*.html|*.yml|*.yaml)
    # package.json 이 있는 가장 가까운 조상에서 prettier 를 찾는다.
    d=$(dirname "$file")
    while [ "$d" != "/" ] && [ "$d" != "." ]; do
      if [ -d "$d/node_modules" ]; then
        ( cd "$d" && npx --no-install prettier --write "$file" >/dev/null 2>&1 )
        break
      fi
      [ "$d" = "$root" ] && break
      d=$(dirname "$d")
    done
    ;;
  *.py)
    command -v ruff >/dev/null 2>&1 && ruff format "$file" >/dev/null 2>&1
    ;;
esac
exit 0
