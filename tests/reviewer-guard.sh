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

# $1=기대(통과|막힘) $2=에이전트 종류(비우면 메인 세션) $3=명령 $4=출력할 이름(비우면 명령)
run() {
  local want=$1 kind=$2 cmd=$3 label=${4:-$3} out got
  out=$(python3 -I -c '
import json, sys
d = {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": sys.argv[2]}}
if sys.argv[1]:
    d["agent_type"] = sys.argv[1]
    d["agent_id"] = "a1"
print(json.dumps(d))' "$kind" "$cmd" | bash "$HOOK" 2>&1)
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then got=막힘; else got=통과; fi
  if [ "$got" = "$want" ]; then ok "${kind:-메인} · $label → $got"
  else bad "${kind:-메인} · $label → $got (기대 $want)"; printf '%s\n' "$out" | sed 's/^/      /'; fi
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
# 셸이 heredoc 을 받으면 본문이 그대로 실행된다 — 본문도 명령으로 본다(사람이 PR 을 열기 전에 짚었다)
run 막힘 cold-reviewer $'bash <<\'EOF\'\ngh pr comment 1 --body x\nEOF'
run 막힘 cold-reviewer $'sh <<\'EOF\'\ngit push origin HEAD\nEOF'
run 막힘 cold-reviewer $'cat <<\'EOF\' | bash\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'/bin/zsh -s <<-EOF\n\tclaude -p x\n\tEOF'
run 막힘 cold-reviewer $'cd /tmp && bash <<EOF\ngh issue comment 1 -b x\nEOF'
run 통과 cold-reviewer $'bash <<\'EOF\'\ngh pr view 1 --json title\ngit -C /tmp/r log -1\nEOF'
run 통과 cold-reviewer $'bash -n /tmp/a.sh; cat > /tmp/s.sh <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
# 셸이 받는 꼴은 `||` 뒤 · `!` · 경로를 붙인 env · 묶음 · source 로도 온다(사람이 PR 을 열기 전에 짚었다)
run 막힘 cold-reviewer $'test -d /tmp || bash <<EOF\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'! bash <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'env A=1 /usr/bin/env bash <<EOF\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'{ bash; } <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'(bash) <<EOF\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'cat <<EOF | (bash -s)\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'source /dev/stdin <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'. /dev/stdin <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
# 명령 앞의 경로를 붙인 감싸는 명령 · 예약어 · 묶음도 건너뛰고 첫 낱말을 본다
run 막힘 cold-reviewer '/usr/bin/env gh pr comment 1 -b x'
run 막힘 cold-reviewer '{ gh pr comment 7 -b x; }'
run 막힘 cold-reviewer 'if true; then gh pr comment 7 -b x; fi'
run 막힘 cold-reviewer 'for i in 1; do git push; done'
# 낱말 안의 따옴표 · \ 는 bash 처럼 떼고 본다
run 막힘 cold-reviewer 'g"h" pr comment 1 -b x'
run 막힘 cold-reviewer '\gh pr comment 1 -b x'
run 막힘 cold-reviewer "git 'push' origin HEAD"
run 막힘 cold-reviewer "\$'g\\x68' pr comment 1 -b x"
run 막힘 cold-reviewer '$"gh" pr comment 1 -b x'
# 예약어 · function · coproc 뒤의 묶음도 읽는다
run 막힘 cold-reviewer 'if true; then { gh pr comment 1 -b x; }; fi'
run 막힘 cold-reviewer 'function f { gh pr comment 1 -b x; }; f'
run 막힘 cold-reviewer 'coproc gh pr comment 1 -b x'
run 막힘 cold-reviewer $'time { bash; } <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'time -p ( bash ) <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'{ echo }; bash; } <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'> /tmp/o bash <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<\'EOF\' && bash -n /tmp/s.sh\ngh pr comment 1 -b x\nEOF'
# 낱말 가운데의 \ 줄 잇기 · 치환 안의 괄호 · \ 로 막은 치환
run 막힘 cold-reviewer $'g\\\nh pr comment 1 -b x'
run 막힘 cold-reviewer 'echo "$( (true); gh pr comment 1 -b x )"'
run 통과 cold-reviewer 'echo "\$(gh pr comment 1 -b x)"'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<EOF\n\\$(gh pr comment 1 -b x)\nEOF'
# heredoc 을 닫는 자리는 bash 가 닫는 자리와 같다 — 끝말에 낱말 글자 밖의 글자가 있거나 앞에 \ 를 붙인 꼴
run 막힘 cold-reviewer $'cat > /tmp/s.sh <<E-1\nx\nE-1\ngh pr comment 1 -b x'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<\\EOF\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'cat > /tmp/s.sh <<\\EOF\nx\nEOF\ngh pr comment 1 -b x'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<"END.1"\ngit push\nEND.1\nbash -n /tmp/s.sh'
# 끝말은 낱말 전체에서 따옴표를 뗀 것이다 · 줄 끝의 | 는 본문 뒤의 줄로 이어진다(사람이 PR 을 열기 전에 짚었다)
run 막힘 cold-reviewer $'cat > /dev/null <<E"O"F\nx\nEOF\ngh pr comment 1 -b x'
run 막힘 cold-reviewer $'cat <<EOF |\ngh pr comment 1 -b x\nEOF\nbash'
run 통과 cold-reviewer $'cat <<EOF |\ngh pr comment 1 -b x\nEOF\ngrep -c gh'
# bash 는 `|` · `&&` · `||` 뒤의 빈 줄 · 주석 줄을 건너뛰며 명령이 끝날 때까지 읽는다(사람이 PR 을 열기 전에 짚었다)
run 막힘 cold-reviewer $'cat <<EOF | # c\ngh pr comment 1 -b x\nEOF\nbash'
run 막힘 cold-reviewer $'cat <<EOF |\ngh pr comment 1 -b x\nEOF\n\nbash'
run 막힘 cold-reviewer $'cat <<EOF |\ngh pr comment 1 -b x\nEOF\n# c\nbash'
run 막힘 cold-reviewer $'cat <<EOF |\ngh pr comment 1 -b x\nEOF\ntee /dev/null |\nbash'
run 막힘 cold-reviewer $'cat <<EOF \\\n| bash\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'{ cat <<\'EOF\'; } | bash\ngh pr comment 1 -b x\nEOF'
# 명령 치환 · 프로세스 치환 안도 명령이다 — 따옴표 안 · 백틱 · 따옴표 없는 끝말의 heredoc 본문에서도
run 막힘 cold-reviewer 'echo "$(gh pr comment 1 -b x)"'
run 막힘 cold-reviewer 'echo `gh pr comment 1 -b x`'
run 막힘 cold-reviewer 'cat <(gh pr comment 1 -b x)'
run 막힘 cold-reviewer $'cat > /tmp/s.sh <<EOF\n$(gh pr comment 1 -b x)\nEOF'
run 막힘 cold-reviewer $'bash <(cat <<\'EOF\'\ngh pr comment 1 -b x\nEOF\n)'
# 출력을 셸에 보내는 프로세스 치환이 있으면 heredoc 을 그 셸이 받을 수 있다
run 막힘 cold-reviewer $'cat <<\'EOF\' > >(bash)\ngh pr comment 1 -b x\nEOF'
run 막힘 cold-reviewer $'exec > >(bash); cat <<\'EOF\'\ngh pr comment 1 -b x\nEOF'
run 통과 cold-reviewer $'cat > /tmp/s.sh <<\'EOF\'\n$(gh pr comment 1 -b x)\nEOF'
run 통과 cold-reviewer 'echo `gh pr view 1 --json title`'
run 통과 cold-reviewer 'diff <(gh pr view 1) /tmp/a'
# 셸에 준 here-string 도 명령으로 본다
run 막힘 cold-reviewer "bash <<< 'gh pr comment 1 -b x'"
run 통과 cold-reviewer "grep -c x <<< 'gh pr comment 1 -b x'"
# 끝말 줄 없이 끝난 heredoc 과 뒤에 명령이 없는 `|` 는 어디까지가 명령인지 판정하지 못한 것이라 막는다
run 막힘 cold-reviewer $'cat > /tmp/s.sh <<EOF\ngh pr view 1'
run 막힘 cold-reviewer "cat > /tmp/s.sh <<'EOF'"
run 막힘 cold-reviewer $'cat <<EOF |\ngh pr view 1\nEOF'
run 막힘 cold-reviewer 'echo $(gh pr view 1'
# 읽다가 예외가 나도 막는다 — 훅이 0이 아닌 코드로 끝나면 명령이 실행된다. 치환을 깊이 겹치면 파이썬의 재귀 한도에 닿는다
deep=$(python3 -I -c 'print("echo " + "$(" * 1100 + "x" + ")" * 1100)')
run 막힘 cold-reviewer "$deep" 'echo $( 를 1100겹 겹친 치환'
run 통과 cold-reviewer "echo \$'\\U7fffffff'"
# 따옴표 안의 << 는 heredoc 이 아니다 — 리뷰어가 heredoc 꼴을 검색한다
run 통과 cold-reviewer "grep -n \"<<'EOF'\" claude-code/skills/open-pr/body.md"
run 통과 cold-reviewer "grep -c '<<EOF' tests/pr-evidence.sh # <<X 는 주석"

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
