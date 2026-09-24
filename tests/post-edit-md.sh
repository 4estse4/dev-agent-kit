#!/usr/bin/env bash
# 편집 직후 포맷 훅(`claude-code/hooks/post_edit.sh`)이 `.md` 를 게이트가 ruff 를 도는 자리에서
# ruff 로도 포맷하는가.
#
# 이 테스트가 있는 이유: ruff 0.16 부터 게이트의 `ruff format --check .`(adapters/py.sh)가 `.md` 의
# Python 코드 블록도 본다. 훅은 `.md` 를 prettier 에만 넘겨서, 에이전트가 README 의 Python 블록을
# 고쳐도 훅은 아무것도 안 하고 pre-commit 게이트가 그제서야 막았다(PR #112 1라운드 콜드 리뷰).
#
# 훅을 Claude Code 가 부르는 모양(표준입력 JSON)으로 부른다. ruff 는 PATH 앞에 둔 가짜로, 부른
# 자리와 받은 인자를 적는다. 진짜 ruff 가 `--force-exclude` 로 `extend-exclude` 를 지키는지는
# PR #112 에 실측으로 있다. 보는 것:
#   · pyproject.toml 이 있는 가장 가까운 조상에서 `ruff format --force-exclude <파일>` 을 부른다
#     — 루트에 있을 때와 하위 디렉터리에 있을 때
#   · 레포 안에 그런 조상이 없으면 부르지 않는다 — pyproject 가 옆 디렉터리나 레포 밖에만 있어도
#   · ruff 가 실패해도(0.15 는 `.md` 에 rc=2) 훅은 rc=0 이다. 0.15 의 게이트는 `.md` 를 안 본다
#   · `.py` 는 전처럼 `ruff format <파일>` 을 부른다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/post_edit.sh"
command -v jq >/dev/null 2>&1 || { echo "  ✗ jq 가 없다 — 훅이 jq 로 입력을 읽는다"; exit 1; }
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# 실경로로 잡는다. 훅은 git 이 내는 실경로(루트)와 파일 경로의 조상을 글자로 견준다.
T=$(cd "$(mktemp -d)" && pwd -P)
R="$T/repo"; mkdir -p "$T/bin" "$R"
git init -q "$R"
cat > "$T/bin/ruff" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_RUFF_LOG"
exit "${STUB_RUFF_RC:-0}"
EOF
chmod +x "$T/bin/ruff"

# 훅은 이 디렉터리들이 PATH 에 없으면 앞에 붙인다. 거기 진짜 ruff 가 있으면 가짜를 가리므로
# 가짜 뒤에 미리 넣어 둔다.
extra="$HOME/go/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin"
command -v go >/dev/null 2>&1 && extra="$(go env GOPATH)/bin:$extra"
P="$T/bin:$extra:$PATH"

layout() { # 인자=pyproject.toml 을 둘 디렉터리($T 기준). 나머지 pyproject.toml 은 지운다
  local d
  find "$T" -name pyproject.toml -delete
  for d in "$@"; do mkdir -p "$T/$d"; printf '[project]\nname="x"\nversion="0"\n' > "$T/$d/pyproject.toml"; done
}

run() { # $1=설명 $2=편집한 파일($R 기준) $3=가짜 ruff 에 남아야 할 기록(비면 안 불려야 한다) [$4=가짜 ruff 의 rc]
  local what=$1 f="$R/$2" want=$3 out rc log
  : > "$T/ruff.log"
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || printf '# x\n' > "$f"
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$f" \
    | (cd "$R" && PATH="$P" STUB_RUFF_LOG="$T/ruff.log" STUB_RUFF_RC="${4:-0}" bash "$HOOK" 2>&1)); rc=$?
  log=$(cat "$T/ruff.log")
  if [ "$rc" = 0 ] && [ "$log" = "$want" ]; then ok "$what"
  else bad "$what → rc=$rc, 기록:"; printf '      [%s]\n' "$log"; printf '      기대 [%s]\n' "$want"; [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/      /'; fi
}

layout repo;      run "루트에 pyproject · README.md"            README.md    "$R|format --force-exclude $R/README.md"
layout repo/py;   run "py/ 에 pyproject · py/docs/x.md"          py/docs/x.md "$R/py|format --force-exclude $R/py/docs/x.md"
layout repo;      run "루트에 pyproject · ruff 가 rc=2(0.15)"     README.md    "$R|format --force-exclude $R/README.md" 2
layout;           run "pyproject 없음 · README.md"               README.md    ""
layout repo/py;   run "pyproject 가 옆 py/ 에만 · README.md"      README.md    ""
layout .;         run "pyproject 가 레포 밖에만 · README.md"      README.md    ""
layout repo;      run ".py 는 전처럼 ruff format"                 m.py         "$R|format $R/m.py"

rm -rf "$T"
exit $fail
