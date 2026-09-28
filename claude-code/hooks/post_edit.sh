#!/usr/bin/env bash
# PostToolUse: 편집한 파일을 자동 포맷한다.
# 포맷만 한다 — 진단은 LSP, 전체 게이트는 git 훅과 CI 가 맡는다. 필요: jq
#
# **이 훅은 차단할 수 없다** — PostToolUse 는 도구가 이미 실행된 뒤에 호출된다(공식 문서).
# 그래서 포매터가 없을 때 할 수 있는 최선은 exit 2 로 에이전트에게 알리는 것이다.
# 실제로 막는 것은 pre-commit 의 게이트다(포맷 검사가 거기서 실행된다).
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
# import 정렬이 알리지 않고 빠지고, 푸시할 때 게이트가 그제야 찾아낸다.
# 실제로 이 킷을 쓰는 머신이 그 상태였다.
#
# lib.sh 를 source 하지 않는 이유: 그쪽은 게이트 상태 배열까지 함께 불러오고, 이 훅은
# 게이트가 복사되지 않은 레포에서도 동작해야 한다. 필요한 만큼만 여기서 한다.
for d in "$(command -v go >/dev/null 2>&1 && go env GOPATH 2>/dev/null)/bin" \
         "$HOME/go/bin" "$HOME/.local/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  case "$d" in ""|"/bin") continue ;; esac
  [ -d "$d" ] || continue
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# 게이트가 ruff 를 실행하는 자리 — pyproject.toml 이 있는 가장 가까운 조상(레포 루트까지) — 를 낸다.
# 없으면 아무것도 안 내고 실패한다.
_pyroot() { # $1=파일
  local d
  d=$(dirname "$1")
  while [ "$d" != "/" ] && [ "$d" != "." ]; do
    [ -f "$d/pyproject.toml" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = "$root" ] && break
    d=$(dirname "$d")
  done
  return 1
}

# 그 자리의 ruff 를 게이트(adapters/py.sh 의 _py)와 같은 순서로 고른다: .venv → venv → PATH.
# 한때 PATH 만 봐서, ruff 를 venv 에 둔 레포에서 게이트와 다른 ruff 를 부르거나 「포매터가
# 없어」로 거짓 알림을 냈다.
_ruff() { # $1=_pyroot 가 낸 디렉터리(비어도 된다)
  local v
  if [ -n "$1" ]; then
    for v in .venv venv; do
      [ -x "$1/$v/bin/ruff" ] && { printf '%s' "$1/$v/bin/ruff"; return 0; }
    done
  fi
  command -v ruff 2>/dev/null
}

case "$file" in
  *.go)
    # 부재와 실행 실패를 구분한다. gofmt 는 구문 오류에 exit 2 를 내는데, 그것을
    # "도구 없음" 으로 보고하면 에이전트가 자기가 만든 구문 오류 대신 설치 안내를 읽는다.
    if command -v gofmt >/dev/null 2>&1; then
      gofmt -w "$file" 2>/dev/null || _failed="gofmt"
    else _missing="gofmt"; fi
    if command -v goimports >/dev/null 2>&1; then
      goimports -w "$file" 2>/dev/null || true
    else _missing="${_missing:+$_missing, }goimports"; fi
    ;;
  *.ts|*.tsx|*.js|*.jsx|*.mjs|*.css|*.scss|*.json|*.md|*.html|*.yml|*.yaml)
    # ruff 0.16 부터 게이트의 `ruff format --check .`(adapters/py.sh)가 .md 의 Python 코드 블록도
    # 본다. 그 게이트가 실행되는 자리(_pyroot)에서 그 게이트의 ruff(_ruff)로도 포맷한다.
    # --force-exclude 가 없으면 이름을 준 파일은 extend-exclude 로 뺀 .md 여도 포맷된다.
    # 실패는 알리지 않는다. 0.15 는 .md 에 rc=2 를 내는데 그 게이트는 .md 를 안 본다.
    # 이것이 없던 동안 훅은 .md 를 prettier 에만 전달해서 pre-commit 게이트가 그제야 막았다.
    case "$file" in
      *.md)
        if d=$(_pyroot "$file") && r=$(_ruff "$d"); then
          ( cd "$d" && "$r" format --force-exclude "$file" >/dev/null 2>&1 )
        fi
        ;;
    esac
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
    # --force-exclude 는 .md 와 같은 이유다. 없으면 프로젝트가 extend-exclude 로 뺀 .py(마이그레이션 ·
    # 생성 코드)도 포맷해, 게이트가 보지 않는 파일에 포맷 변경이 섞였다.
    # 제외된 파일에는 경고와 rc=0 을 내므로 실패 판정은 그대로다.
    if r=$(_ruff "$(_pyroot "$file")"); then
      "$r" format --force-exclude "$file" >/dev/null 2>&1 || _failed="ruff"
    else _missing="ruff"; fi
    ;;
  *.kt|*.kts)
    # JVM 에는 gofmt 같은 "어디에나 있는 단일 파일 포매터" 가 없다. 있는 것만 쓰고
    # 없으면 그냥 건너뛴다 — 여기서 gradle spotlessApply 를 부르면 편집 한 번에
    # JVM 기동 비용이 붙는다. 그건 편의가 아니라 편집마다 드는 비용이고, 게이트가 어차피 찾아낸다.
    if command -v ktfmt >/dev/null 2>&1; then
      ktfmt "$file" >/dev/null 2>&1
    elif command -v ktlint >/dev/null 2>&1; then
      ktlint -F "$file" >/dev/null 2>&1
    else
      _missing="ktlint"
    fi
    ;;
esac

# 포매터가 없으면 알린다. 예전에는 알리지 않고 건너뛰어서, 포맷이 안 된 채 진행되다가
# 커밋·푸시에서야 드러났다. exit 2 는 stderr 를 에이전트에게 보여준다.
# 실행 실패는 대개 편집 중간 상태의 구문 오류다 — 알리되 설치 안내를 붙이지 않는다.
if [ -n "${_failed:-}" ]; then
  echo "post_edit: ${_failed} 가 ${file##*/} 을 포맷하지 못했습니다 — 구문 오류일 수 있습니다." >&2
  exit 2
fi
if [ -n "${_missing:-}" ]; then
  echo "post_edit: 포매터가 없어 ${file##*/} 을 포맷하지 못했습니다 — ${_missing}" >&2
  echo "  설치: bash .ai-kit/gate/install-tools.sh   (버전은 .ai-kit/gate/tool-versions)" >&2
  exit 2
fi
exit 0
