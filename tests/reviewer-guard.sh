#!/usr/bin/env bash
# 리뷰어 가드(`claude-code/hooks/reviewer_guard.sh`)가 콜드 리뷰어의 GitHub 쓰기 · 푸시 · 새 세션 띄우기를 막는가.
#
# 이 테스트가 있는 이유: 콜드 리뷰어가 게시하지 않는 것은 정의의 「게시하지 마라」 절만 지켰다. 그 절이 근거로 드는
# 사고에서는 사람 승인 없이 코멘트 40건이 나갔고 그중 20건을 리뷰어가 올렸다. 리뷰어가 새 Claude 세션을 띄워 실험한
# 일도 있었다(이슈 #188 코멘트). 설정 파일의 훅은 서브에이전트의 도구 호출에도 실행되고 입력에 `agent_type` 이 실려,
# 가드는 `cold-reviewer` 의 명령만 본다.
#
# 훅을 Claude Code 가 부르는 모양(표준입력 JSON)으로 부른다. 명령은 실행되지 않는다 — 훅의 판정만 본다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/reviewer_guard.sh"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# $1=기대(통과|막힘) $2=에이전트 종류(비우면 메인 세션) $3=명령
run() {
  local want=$1 kind=$2 cmd=$3 out got
  out=$(python3 -I -c '
import json, sys
d = {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": sys.argv[2]}}
if sys.argv[1]:
    d["agent_type"] = sys.argv[1]
    d["agent_id"] = "a1"
print(json.dumps(d))' "$kind" "$cmd" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=막힘; else got=통과; fi
  if [ "$got" = "$want" ]; then ok "${kind:-메인} · $cmd → $got"
  else bad "${kind:-메인} · $cmd → $got (기대 $want)"; printf '%s\n' "$out" | sed 's/^/      /'; fi
}

# 콜드 리뷰어의 쓰기는 막힌다
run 막힘 cold-reviewer 'gh pr comment 7 --body-file /tmp/x.md'
run 막힘 cold-reviewer 'gh pr review 7 --approve'
run 막힘 cold-reviewer 'gh -R o/r pr comment 7 -b hi'
run 막힘 cold-reviewer 'gh issue comment 7 --body hi'
run 막힘 cold-reviewer 'gh issue create --title t --body b'
run 막힘 cold-reviewer 'gh pr edit 7 --body x'
run 막힘 cold-reviewer 'gh pr merge 7 --squash'
run 막힘 cold-reviewer 'gh pr checkout 7'
run 막힘 cold-reviewer 'gh api repos/o/r/issues/7/comments -f body=hi'
run 막힘 cold-reviewer 'gh api -X POST repos/o/r/issues/7/comments'
run 막힘 cold-reviewer 'gh api --method=PATCH repos/o/r/issues/7'
run 막힘 cold-reviewer 'gh api repos/o/r/issues --input /tmp/b.json'
run 막힘 cold-reviewer 'git push origin HEAD'
run 막힘 cold-reviewer 'git -C /tmp/repo push'
run 막힘 cold-reviewer 'claude -p "check this"'
run 막힘 cold-reviewer '/usr/local/bin/claude --version'
run 막힘 cold-reviewer 'cd /tmp/repo && git push'
run 막힘 cold-reviewer 'gh pr view 7; gh pr comment 7 -b x'
run 막힘 cold-reviewer 'echo x | gh pr comment 7 --body-file -'
run 막힘 cold-reviewer 'FOO=1 gh pr comment 7 -b x'
run 막힘 cold-reviewer "gh pr comment 7 -b 'unterminated"
run 막힘 cold-reviewer $'gh pr view 7\ngh pr comment 7 -b x'

# 콜드 리뷰어의 읽기와 스크래치 작업은 통과한다
run 통과 cold-reviewer 'gh pr view 246 --json headRefOid -q .headRefOid'
run 통과 cold-reviewer 'gh pr diff 246 --name-only'
run 통과 cold-reviewer 'gh pr checks 246'
run 통과 cold-reviewer 'gh issue view 107 --json body'
run 통과 cold-reviewer 'gh run view 1 --log'
run 통과 cold-reviewer 'gh api repos/o/r/pulls/7'
run 통과 cold-reviewer 'gh api -X GET repos/o/r/issues -f state=open'
run 통과 cold-reviewer 'd=$(mktemp -d) && git clone -q /tmp/repo "$d/repo" && git -C "$d/repo" log --oneline -3'
run 통과 cold-reviewer 'grep -n "gh pr comment" claude-code/skills/open-pr/round.md'
run 통과 cold-reviewer 'bash tests/post-length.sh'
# 리뷰어는 Write 를 못 써서 스크래치 스크립트를 heredoc 으로 쓴다. 본문은 실행되는 명령이 아니다
run 통과 cold-reviewer $'cat > /tmp/s.sh <<\'EOF\'\ngit push origin HEAD\ngh pr comment 7 -b "x\nEOF\nbash -n /tmp/s.sh'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<-EOF\n\tclaude -p x\n\tEOF'
run 막힘 cold-reviewer $'cat > /tmp/s.sh <<EOF\nx\nEOF\ngh pr comment 7 -b x'

# 메인 세션과 다른 에이전트는 이 가드가 보지 않는다
run 통과 '' 'gh pr comment 7 --body-file /tmp/x.md'
run 통과 '' 'git push origin HEAD'
run 통과 Explore 'gh pr comment 7 -b x'
run 통과 general-purpose 'claude -p "x"'
# 명령에 그 글자가 들어 있어도 에이전트 종류로 거른다 — 셸의 빠른 판정을 지나 파이썬 판정까지 간다
run 통과 '' 'gh pr comment 7 --body-file /tmp/cold-reviewer-round1.md'
run 통과 Explore 'cat claude-code/agents/cold-reviewer.md && git push'

# 설치되는 settings 는 설치된 킷의 훅(.claude/hooks/)을, 이 레포의 settings 는 원본(claude-code/hooks/)을 가리킨다
for pair in "claude-code/settings.json:.claude/hooks/reviewer_guard.sh" ".claude/settings.json:claude-code/hooks/reviewer_guard.sh"; do
  s=${pair%%:*} want=${pair#*:}
  if python3 -I - "$KIT/$s" "$want" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))['hooks']
sys.exit(0 if any(m.get('matcher') == 'Bash' and any(sys.argv[2] in x.get('command', '') for x in m['hooks'])
                  for m in h.get('PreToolUse', [])) else 1)
PY
  then ok "${s} 가 ${want} 를 PreToolUse(Bash)에 등록한다"
  else bad "${s} 가 ${want} 를 PreToolUse(Bash)에 등록하지 않는다"; fi
done

exit $fail
