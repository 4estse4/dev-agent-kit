#!/usr/bin/env bash
# PostToolUse: 편집한 파일을 자동 포맷한다.
# 포맷만 한다 — 진단은 LSP, 전체 게이트는 git 훅과 CI 가 맡는다.
# 절대 차단하지 않는다. 필요: jq
input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# 게이트와 같은 방식으로 PATH 를 넓힌다.
#
# 왜 필요한가 — `go install` 로 받은 도구는 GOPATH/bin 에 들어가는데 그 경로를 PATH 에
# 넣어두지 않은 환경이 흔하다. 게이트(lib.sh 의 gate_extend_path)는 이걸 하는데 이 훅은
# 안 해서, **게이트는 goimports 를 찾고 이 훅은 못 찾는** 상태가 된다. 그러면 편집 시
# import 정렬이 조용히 빠지고, 푸시할 때 게이트가 그제서야 잡는다.
# 실제로 이 킷을 쓰는 머신이 그 상태였다.
#
# lib.sh 를 source 하지 않는 이유: 그쪽은 게이트 상태 배열까지 들고 오고, 이 훅은
# vendor 된 게이트가 없는 레포에서도 돌아야 한다. 필요한 만큼만 여기서 한다.
for d in "$(command -v go >/dev/null 2>&1 && go env GOPATH 2>/dev/null)/bin" \
         "$HOME/go/bin" "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  case "$d" in ""|"/bin") continue ;; esac
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

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
