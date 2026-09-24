#!/usr/bin/env bash
# 편집 직후 포맷 훅(`claude-code/hooks/post_edit.sh`)이 게이트와 같은 자리에서 같은 ruff 를 부르는가.
#
# 이 테스트가 있는 이유: ruff 0.16 부터 게이트의 `ruff format --check .`(adapters/py.sh)가 `.md` 의
# Python 코드 블록도 본다. 훅은 `.md` 를 prettier 에만 넘겨서, 에이전트가 README 의 Python 블록을
# 고쳐도 훅은 아무것도 안 하고 pre-commit 게이트가 그제서야 막았다(PR #112 1라운드 콜드 리뷰).
# 그것을 고친 뒤에도 훅은 PATH 의 ruff 만 봤다. 게이트는 그 자리의 `.venv` · `venv` 의 ruff 를 먼저
# 쓰므로, 프로젝트가 ruff 를 venv 에 둔 레포에서는 같은 일이 났고 `.py` 는 「포매터가 없어」로
# 거짓 알림을 냈다(PR #112 2라운드 콜드 리뷰).
#
# 훅을 Claude Code 가 부르는 모양(표준입력 JSON)으로 부른다. ruff 는 가짜로, 부른 자리와 받은
# 인자를 적는다. PATH 의 것과 venv 의 것은 기록의 머리(`venv|`)로 가른다. 진짜 ruff 가
# `--force-exclude` 로 `extend-exclude` 를 지키는지는 PR #112 의 2라운드 코멘트에 실제로 확인한 결과로 있다.
# 보는 것:
#   · `.md` 면 pyproject.toml 이 있는 가장 가까운 조상에서 `ruff format --force-exclude <파일>` 을
#     부른다 — 루트에 있을 때와 하위 디렉터리에 있을 때
#   · 레포 안에 그런 조상이 없으면 부르지 않는다 — pyproject 가 옆 디렉터리나 레포 밖에만 있어도
#   · ruff 가 실패해도(0.15 는 `.md` 에 rc=2) 훅은 rc=0 이다. 0.15 의 게이트는 `.md` 를 안 본다
#   · ruff 는 게이트처럼 그 조상의 `.venv` → `venv` → PATH 순으로 고른다. `.md` 도 `.py` 도.
#     venv 는 그 조상의 것만 본다 — 레포 루트의 venv 는 하위 디렉터리의 pyproject 에 안 쓴다
#   · `.py` 는 전처럼 훅이 도는 자리에서 부르되 `--force-exclude` 를 붙인다. 없으면 프로젝트가
#     extend-exclude 로 뺀 `.py`(마이그레이션 등)도 포맷했다(PR #112 3라운드 콜드 리뷰)
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
cat > "$T/venv-ruff" <<'EOF'
#!/usr/bin/env bash
printf 'venv|%s|%s\n' "$PWD" "$*" >> "$STUB_RUFF_LOG"
exit "${STUB_RUFF_RC:-0}"
EOF
chmod +x "$T/bin/ruff" "$T/venv-ruff"

# 훅은 이 디렉터리들이 PATH 에 없으면 앞에 붙인다. 거기 진짜 ruff 가 있으면 가짜를 가리므로
# 가짜 뒤에 미리 넣어 둔다.
extra="$HOME/go/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin"
command -v go >/dev/null 2>&1 && extra="$(go env GOPATH)/bin:$extra"
P="$T/bin:$extra:$PATH"

layout() { # 인자=pyproject.toml 을 둘 디렉터리($T 기준). 나머지 pyproject.toml 과 venv 는 지운다
  local d
  find "$T" -name pyproject.toml -delete
  rm -rf "$R/.venv" "$R/venv" "$R/py/.venv" "$R/py/venv"
  for d in "$@"; do mkdir -p "$T/$d"; printf '[project]\nname="x"\nversion="0"\n' > "$T/$d/pyproject.toml"; done
}

venv() { # $1=venv 디렉터리($R 기준, 예: .venv · py/venv). 그 안의 bin/ruff 에 가짜를 둔다
  mkdir -p "$R/$1/bin"; cp "$T/venv-ruff" "$R/$1/bin/ruff"
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
layout repo;      run ".py 도 --force-exclude 로"                 m.py         "$R|format --force-exclude $R/m.py"

# 게이트의 _py 처럼 그 조상의 venv 를 PATH 보다 먼저 본다.
layout repo;    venv .venv;    run ".md · 루트 .venv 의 ruff"            README.md    "venv|$R|format --force-exclude $R/README.md"
layout repo/py; venv py/venv;  run ".md · py/venv 의 ruff"               py/docs/x.md "venv|$R/py|format --force-exclude $R/py/docs/x.md"
layout repo;    venv .venv;    run ".py · 루트 .venv 의 ruff"            m.py         "venv|$R|format --force-exclude $R/m.py"
layout repo/py; venv py/.venv; run ".py · py/.venv 의 ruff"              py/m.py      "venv|$R|format --force-exclude $R/py/m.py"
layout repo/py; venv .venv;    run ".md · venv 가 레포 루트에만(pyproject 는 py/)" py/docs/x.md "$R/py|format --force-exclude $R/py/docs/x.md"

rm -rf "$T"
exit $fail
