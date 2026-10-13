#!/usr/bin/env bash
# 킷의 git 훅이 꺼진 clone 에서, 세션 시작 훅이 그것을 알리고 에이전트 훅이 `git commit` · `git push` 를 막는가.
#
# 이 테스트가 있는 이유: 훅 파일은 `.kit/git-hooks/` 에 커밋되어 clone 을 따라오지만, 그것을 켜는
# `core.hooksPath` 는 `.git/config` 에 있어 clone 에 담기지 않는다(git 이 일부러 그렇게 만들었다). 그래서 clone 한
# 레포에서 일하는 세션은 훅이 꺼진 줄 모르고 커밋 · 푸시했고, 막히는 것은 CI 에서였다(이슈 #27). 사람이 정했다 —
# 세션 시작 때 알리고, 꺼진 동안은 에이전트 훅이 `git commit` · `git push` 를 막고 켜는 명령을 알린다. 알림은 세션이
# 읽고 따라야 지켜지지만, 막으면 켜기 전에는 세션이 커밋도 푸시도 하지 못한다.
#
# 훅을 직접 놓지 않고 설치기를 거친다(`install.sh <레포> --hooks --agent` 가 `.claude/hooks/` 에 훅을 놓고 등록한다).
# 설치한 레포를 clone 하면 훅이 꺼진 레포가 된다. 보는 것:
#   · 세션 시작 훅: 꺼진 clone 에서 알리고 켜는 명령을 적는다. 켜진 레포와 `.kit/git-hooks/` 가 없는 레포에서는
#     아무것도 출력하지 않는다
#   · 에이전트 훅: 꺼진 clone 에서 `git commit` · `git push` 를 막고 사유에 켜는 명령을 적는다 — 하위 디렉터리에서
#     입력한 것, 레포 밖에서 `git -C <그 clone>` 으로 입력한 것, 그 clone 의 worktree 에서 입력한 것, 전역 옵션
#     (`--no-pager` · `-c <키=값>`) 뒤의 것, 명령이 시작되는 여러 자리(`&&` · `;` · `(` · `$(` · `bash -c '` · 앞의
#     `이름=값` · `env` · `then` 뒤)의 것도. 다른 git 명령(`status` · `log --grep commit` · `--no-pager log --grep
#     commit` · `stash push` · `commit-tree` · `config`), 검색 · `echo` 의 인자에 든 글자, git 이 아닌 명령은 막지 않는다
#   · 켜진 레포 · `.kit/git-hooks/` 가 없는 레포 · 세션을 연 프로젝트 밖의 레포(실험용 clone)에서는 막지 않는다.
#     꺼진 clone 에서 `git -C <켜진 레포>` 로 입력한 커밋도 막지 않는다
#   · `core.hooksPath` 를 절대 경로로 켜도 켜진 것으로 보고, 다른 디렉터리를 가리키면 꺼진 것으로 본다
#   · 킷의 `settings.json` 이 이 훅을 `SessionStart` 와 `PreToolUse`(Bash)에 등록한다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
newrepo() { # $1=경로
  git init -q -b main "$1"; git -C "$1" config user.email t@example.com; git -C "$1" config user.name T
  git -C "$1" commit -q --allow-empty -m init
}
R="$T/app"; C="$T/clone"; N="$T/agent-only"
newrepo "$R"
bash "$KIT/install.sh" "$R" --hooks --agent > "$T/install.log" 2>&1 || { bad "설치가 실패했다"; tail -5 "$T/install.log"; exit 1; }
git -C "$R" add -A; git -C "$R" commit -q --no-verify -m kit
git clone -q "$R" "$C"
# 세션을 연 프로젝트 밖에서 실험하려고 만든 clone — 훅이 꺼져 있지만 프로젝트의 커밋이 아니다
X="$T/scratch"; git clone -q "$R" "$X"
git -C "$C" config user.email t@example.com; git -C "$C" config user.name T
mkdir -p "$C/sub"
newrepo "$N"
bash "$KIT/install.sh" "$N" --agent > "$T/install-n.log" 2>&1 || { bad "--agent 설치가 실패했다"; tail -5 "$T/install-n.log"; exit 1; }

H="$C/.claude/hooks/hooks_path.sh"
if [ ! -f "$H" ]; then
  bad "설치한 레포의 clone 에 .claude/hooks/hooks_path.sh 가 없다"
  exit 1
fi
ENABLE='git config core.hooksPath .kit/git-hooks'

session() { # $1=프로젝트 — 세션 시작 훅을 부르고 출력을 $out 에 둔다
  out=$(cd "$1" && printf '{"session_id": "s1", "cwd": "%s", "hook_event_name": "SessionStart", "source": "startup"}' "$1" \
    | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/hooks_path.sh" 2>&1)
}
pre() { # $1=프로젝트 $2=cwd $3=명령 — 에이전트 훅을 부르고 출력을 $out 에 둔다
  out=$(cd "$2" && python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "cwd": sys.argv[1], "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$2" "$3" \
    | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/hooks_path.sh" 2>&1)
}
denied() { printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; }
blocks() { # $1=설명 $2=프로젝트 $3=cwd $4=명령
  pre "$2" "$3" "$4"
  if denied && printf '%s' "$out" | grep -qF "$ENABLE"; then ok "$1"
  else bad "$1 — 막고 켜는 명령을 적어야 한다: [$out]"; fi
}
passes() { # $1=설명 $2=프로젝트 $3=cwd $4=명령
  pre "$2" "$3" "$4"
  if denied; then bad "$1 — 막지 않아야 한다: [$out]"; else ok "$1"; fi
}

echo "── 세션 시작 훅"
session "$C"
if printf '%s' "$out" | grep -qF "$ENABLE" && printf '%s' "$out" | grep -qF 'git commit'; then
  ok "훅이 꺼진 clone 에서 세션 시작 때 알리고 켜는 명령을 적는다"
else bad "훅이 꺼진 clone 에서 세션 시작 때 알려야 한다: [$out]"; fi
session "$R"
[ -z "$out" ] && ok "훅이 켜진 레포에서는 아무것도 출력하지 않는다" || bad "훅이 켜진 레포에서 출력했다: [$out]"
session "$N"
[ -z "$out" ] && ok ".kit/git-hooks 가 없는 레포에서는 아무것도 출력하지 않는다" || bad ".kit/git-hooks 가 없는 레포에서 출력했다: [$out]"

echo "── 에이전트 훅 — 훅이 꺼진 clone"
blocks "git commit 을 막는다" "$C" "$C" "git commit -qm x"
blocks "git push 를 막는다" "$C" "$C" "git push origin main"
blocks "하위 디렉터리에서 입력한 git commit 을 막는다" "$C" "$C/sub" "git add -A && git commit -qm x"
blocks "레포 밖에서 git -C 로 입력한 git commit 을 막는다" "$C" "$T" "git -C $C commit -qm x"
passes "git status 는 막지 않는다" "$C" "$C" "git status --short"
passes "git log --grep commit 은 막지 않는다" "$C" "$C" "git log --grep commit --oneline"
passes "git commit-tree 는 막지 않는다" "$C" "$C" "git commit-tree HEAD^{tree} -m x"
passes "훅을 켜는 git config 는 막지 않는다" "$C" "$C" "$ENABLE"
passes "git 이 아닌 명령은 막지 않는다" "$C" "$C" "echo hello"
passes "꺼진 clone 에서 git -C 로 켜진 레포에 커밋하는 것은 막지 않는다" "$C" "$C" "git -C $R commit -qm x"
# 인자를 받지 않는 전역 옵션 뒤의 낱말을 그 옵션의 값으로 읽으면 하위 명령이 아닌 낱말을 하위 명령으로 본다
passes "인자를 받지 않는 전역 옵션 뒤의 git log --grep commit 은 막지 않는다" "$C" "$C" "git --no-pager log --grep commit --oneline"
passes "인자를 받지 않는 전역 옵션 뒤의 git stash push 는 막지 않는다" "$C" "$C" "git -P stash push -m wip"
blocks "인자를 받지 않는 전역 옵션 뒤의 git commit 은 막는다" "$C" "$C" "git --no-pager commit -qm x"
blocks "값을 받는 전역 옵션 뒤의 git push 를 막는다" "$C" "$C" "git -c color.ui=never push origin main"
# 찾는 것은 명령이 시작되는 자리의 git 이다. 검색 · echo 의 글자를 막으면 켜지 않기로 한 레포에서 끝까지 막힌다
passes "검색 명령의 글자 git push 는 막지 않는다" "$C" "$C" "grep -rn 'git push' .claude/skills"
passes "echo 의 글자 git commit 은 막지 않는다" "$C" "$C" "echo \"run git commit -m x\""
blocks "sh -c 안의 git push 를 막는다" "$C" "$C" "bash -c 'git push origin main'"
blocks "괄호 안의 git push 를 막는다" "$C" "$C" "(cd sub; git push origin main)"
blocks "명령 치환 안의 git commit 을 막는다" "$C" "$C" 'x=$(git commit -qm x)'
blocks "앞에 이름=값을 붙인 git commit 을 막는다" "$C" "$C" "GIT_AUTHOR_NAME=x git commit -qm x"
blocks "env 뒤의 git commit 을 막는다" "$C" "$C" "env GIT_AUTHOR_NAME=x git commit -qm x"
blocks "then 뒤의 git commit 을 막는다" "$C" "$C" "if true; then git commit -qm x; fi"
# 판정하는 것은 세션을 연 프로젝트의 레포다. 같은 git 공통 디렉터리를 쓰는 worktree 는 그 레포다
passes "프로젝트 밖의 실험용 clone 에 git -C 로 커밋하는 것은 막지 않는다" "$C" "$C" "git -C $X commit -qm x"
passes "프로젝트 밖의 실험용 clone 에서 입력한 커밋은 막지 않는다" "$C" "$X" "git commit -qm x"
git -C "$C" worktree add -q "$T/wt" -b wt-branch
blocks "프로젝트의 worktree 에서 입력한 git commit 을 막는다" "$C" "$T/wt" "git commit -qm x"

echo "── 에이전트 훅 — 막지 않는 레포"
passes "훅이 켜진 레포의 git commit 은 막지 않는다" "$R" "$R" "git commit -qm x"
passes ".kit/git-hooks 가 없는 레포의 git commit 은 막지 않는다" "$N" "$N" "git commit -qm x"

echo "── core.hooksPath 의 값"
git -C "$C" config core.hooksPath "$C/.kit/git-hooks"
passes "절대 경로로 켠 clone 의 git commit 은 막지 않는다" "$C" "$C" "git commit -qm x"
git -C "$C" config core.hooksPath .githooks
blocks "다른 디렉터리를 가리키는 clone 의 git commit 은 막는다" "$C" "$C" "git commit -qm x"
git -C "$C" config core.hooksPath .kit/git-hooks
passes "켠 clone 의 git push 는 막지 않는다" "$C" "$C" "git push origin main"
# 상대 경로는 레포 루트 기준이다. 하위 디렉터리에서 입력해야 훅이 실행된 디렉터리 기준으로 푸는 실수가 드러난다
passes "켠 clone 의 하위 디렉터리에서 입력한 git commit 은 막지 않는다" "$C" "$C/sub" "git commit -qm x"

echo "── 등록"
for s in "$KIT/claude-code/settings.json" "$C/.claude/settings.json"; do
  case "$s" in "$KIT"/*) name="킷의 ${s#"$KIT"/}" ;; *) name="설치한 레포의 clone 의 .claude/settings.json" ;; esac
  if python3 - "$s" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))['hooks']
def has(ev, matcher):
    return any(m.get('matcher', '') == matcher and any('hooks_path.sh' in x.get('command', '') for x in m['hooks'])
               for m in h.get(ev, []))
sys.exit(0 if has('SessionStart', '') and has('PreToolUse', 'Bash') else 1)
PY
  then ok "${name} 가 hooks_path.sh 를 SessionStart 와 PreToolUse(Bash)에 등록한다"
  else bad "${name} 가 hooks_path.sh 를 SessionStart 와 PreToolUse(Bash)에 등록하지 않는다"; fi
done

[ "$fail" = 0 ] && echo "  ✓ 훅이 꺼진 clone 에서 세션이 알림을 받고 커밋 · 푸시가 막힌다"
exit $fail
