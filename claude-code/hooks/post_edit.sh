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
  *.kt|*.kts)
    # JVM 에는 gofmt 같은 "어디에나 있는 단일 파일 포매터" 가 없다. 있는 것만 쓰고
    # 없으면 그냥 넘어간다 — 여기서 gradle spotlessApply 를 부르면 편집 한 번에
    # JVM 기동 비용이 붙는다. 그건 편의가 아니라 세금이고, 게이트가 어차피 잡는다.
    if command -v ktfmt >/dev/null 2>&1; then
      ktfmt "$file" >/dev/null 2>&1
    elif command -v ktlint >/dev/null 2>&1; then
      ktlint -F "$file" >/dev/null 2>&1
    fi
    ;;
  *.java)
    command -v google-java-format >/dev/null 2>&1 \
      && google-java-format -i "$file" >/dev/null 2>&1
    ;;
esac
exit 0
