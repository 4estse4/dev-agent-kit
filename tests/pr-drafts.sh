#!/usr/bin/env bash
# PR 본문 · 코멘트 조각의 자리(`claude-code/skills/open-pr/drafts.sh`)를 git 이 보지 않고, 편집 직후 포맷 훅이
# 그 조각을 고치지 않는가.
#
# 이 테스트가 있는 이유: 조각을 git 디렉터리 안에 두었더니 그 자리가 Claude Code 의 보호 경로라, 조각을 쓰고 고칠
# 때마다 권한 프롬프트가 표시됐다(이슈 #107). 작업 트리 안으로 옮기면 두 가지가 새로 생긴다 — git 이 그 파일을 볼 수
# 있고, 포맷 훅(`post_edit.sh`)이 `.md` 조각을 고친다. 고쳐지면 사람이 창에서 본 글과 올라가는 글이 달라진다.
# 훅이 조각을 고친다는 것은 사람이 계획 단계에서 짚었다.
#
# 보는 것:
#   · 레포 루트 · 하위 디렉터리 · worktree 에서 부르면 그 루트의 `.kit/drafts/` 아래 새 디렉터리의 절대 경로를 낸다
#   · 두 번 부르면 다른 디렉터리를 낸다
#   · 조각을 쓴 뒤에도 `git status --porcelain` 이 비어 있다
#   · 훅을 Claude Code 가 부르는 모양(표준입력 JSON)으로 부른다. 조각 자리의 `.md` 는 그대로고, 같은 레포의 다른
#     `.md` 는 ruff 와 prettier 가 고친다. 가짜 포매터는 불리면 파일에 줄을 더한다 — 다른 `.md` 가 고쳐지지 않으면
#     조각이 그대로인 것도 훅이 포매터를 부르지 않는 다른 까닭 때문일 수 있다
#   · 이름을 주지 않으면 실패하고 아무것도 만들지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
DRAFTS="$KIT/claude-code/skills/open-pr/drafts.sh"
HOOK="$KIT/claude-code/hooks/post_edit.sh"
command -v jq >/dev/null 2>&1 || { echo "  ✗ jq 가 없다 — 훅이 jq 로 입력을 읽는다"; exit 1; }
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# 실경로로 정한다. git 이 내는 루트는 실경로다(macOS 의 /var → /private/var).
T=$(cd "$(mktemp -d)" && pwd -P)
R="$T/repo"; mkdir -p "$R/sub" "$T/bin"
git init -q "$R"; git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
echo x > "$R/sub/keep"; git -C "$R" add -A; git -C "$R" commit -q -m init

# $1=설명 $2=부를 디렉터리 $3=조각 자리가 있어야 할 루트
place() {
  local what=$1 cwd=$2 root=$3 out rc
  out=$(cd "$cwd" && bash "$DRAFTS" pr-body 2>&1); rc=$?
  case "$out" in
    "$root/.kit/drafts/pr-body."*)
      if [ "$rc" = 0 ] && [ -d "$out" ]; then ok "$what → ${out#"$T"/}"; printf '%s' "$out" > "$T/last"
      else bad "$what → rc=$rc, 디렉터리 아님: $out"; fi ;;
    *) bad "$what → rc=$rc, 출력이 $root/.kit/drafts/pr-body.* 가 아니다: $out" ;;
  esac
}

place "레포 루트에서 부름" "$R" "$R"
first=$(cat "$T/last" 2>/dev/null)
place "하위 디렉터리에서 부름" "$R/sub" "$R"
second=$(cat "$T/last" 2>/dev/null)
if [ -n "$first" ] && [ "$first" != "$second" ]; then ok "두 번 부르면 다른 디렉터리"
else bad "두 번 부른 출력이 같거나 비었다: [$first] [$second]"; fi

git -C "$R" worktree add -q "$T/wt" -b wt 2>/dev/null
place "worktree 에서 부름" "$T/wt" "$T/wt"
wt=$(cat "$T/last" 2>/dev/null)

# 조각을 쓴 뒤 git 이 아무것도 보지 않는다
for d in "$first" "$wt"; do
  [ -n "$d" ] || continue
  printf '## 문제\n' > "$d/10-head.part"; printf '* 항목\n' > "$d/self.md"
done
for r in "$R" "$T/wt"; do
  st=$(git -C "$r" status --porcelain)
  if [ -z "$st" ]; then ok "조각을 쓴 뒤 git status 가 비어 있다(${r#"$T"/})"
  else bad "조각을 쓴 뒤 git status 가 비지 않았다(${r#"$T"/}):"; printf '      %s\n' "$st"; fi
done

# 이름을 주지 않으면 실패하고 아무것도 만들지 않는다
E="$T/empty"; git init -q "$E"
out=$(cd "$E" && bash "$DRAFTS" 2>&1); rc=$?
if [ "$rc" != 0 ] && [ ! -e "$E/.kit" ]; then ok "이름 없이 부르면 rc=$rc 이고 아무것도 만들지 않는다"
else bad "이름 없이 불렀는데 rc=$rc · .kit $([ -e "$E/.kit" ] && echo 있음 || echo 없음) · 출력 [$out]"; fi

# 포맷 훅. 가짜 ruff · npx 는 불리면 마지막 인자(파일)에 자기 이름을 한 줄 더한다.
for t in ruff npx; do
  cat > "$T/bin/$t" <<EOF
#!/usr/bin/env bash
for f; do :; done
printf '%s\n' '# $t' >> "\$f"
EOF
  chmod +x "$T/bin/$t"
done
# 훅은 이 디렉터리들이 PATH 에 없으면 앞에 붙인다. 거기 진짜 도구가 있으면 가짜를 가리므로 가짜 뒤에 미리 넣어 둔다.
extra="$HOME/go/bin:$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin"
command -v go >/dev/null 2>&1 && extra="$(go env GOPATH)/bin:$extra"
P="$T/bin:$extra:$PATH"
# ruff 는 pyproject.toml 이 있는 조상에서, prettier 는 node_modules 가 있는 조상에서 부른다(post_edit.sh)
printf '[project]\nname="x"\nversion="0"\n' > "$R/pyproject.toml"; mkdir -p "$R/node_modules"

# $1=설명 $2=편집한 파일 $3=훅을 지난 뒤 있어야 할 내용
hook() {
  local what=$1 f=$2 want=$3 got
  printf '* 항목\n' > "$f"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$f" | (cd "$R" && PATH="$P" bash "$HOOK" >/dev/null 2>&1)
  got=$(cat "$f")
  if [ "$got" = "$want" ]; then ok "$what"
  else bad "$what → 내용:"; printf '      [%s]\n' "$got"; printf '      기대 [%s]\n' "$want"; fi
}
hook "조각 자리 밖의 .md 는 ruff 와 prettier 가 고친다" "$R/notes.md" "$(printf '* 항목\n# ruff\n# npx')"
[ -n "$first" ] && hook "조각 자리의 .md 는 훅을 지나도 그대로다" "$first/self.md" "* 항목"
[ -n "$second" ] && hook "하위 디렉터리에서 만든 조각 자리의 .md 도 그대로다" "$second/round.md" "* 항목"

exit $fail
