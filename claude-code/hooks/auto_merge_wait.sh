#!/usr/bin/env bash
# PostToolUse(Bash): `gh pr merge --auto` 가 성공하면, 대기 스크립트(`wait_merge.sh`)를 백그라운드로 켜라고 세션에
# 알린다. 필요: python3 · git
#
# **왜.** auto-merge 를 켜면 머지는 사람이 Approve 한 순간 GitHub 이 하므로, 세션은 머지를 알 길이 없다. 대기
# 스크립트가 머지나 사람이 봐야 할 일을 보고 끝나면 Claude Code 가 세션을 깨운다. 그 스크립트를 켜는 것을 스킬
# 문서(`merge-pr` 3절)에만 적어 두면, 컴팩션 뒤나 스킬을 읽지 않은 세션이 빠뜨린다. 그래서 켜는 명령이 성공한
# 바로 그 자리에서 알린다. 알림은 `additionalContext` 로 모델의 맥락에 들어간다.
#
# **성공했을 때만.** PostToolUse 는 종료 코드 0 으로 끝난 Bash 뒤에만 실행된다 — 0 이 아니면 `PostToolUseFailure`
# 가 실행된다(`claude -p` 로 `true` 와 `false` 를 실행해 확인했다). 막기 훅이 막은 명령은 실행되지 않아 이 훅도
# 실행되지 않는다.
#
# **명령 글자로 알아본다.** 명령을 셸 연산자(`&&` · `;` · `|`)로 나눈 조각 가운데 첫 낱말이 `gh` 이고 `pr merge`
# 가 이어지며, 값을 받는 플래그의 값이 아닌 자리에 `--auto`(또는 `--auto=` 가 false · 0 이 아닌 것)가 있는
# 조각이다. `--disable-auto` 는 끄는 것이다. 스크립트 파일 안의 호출은 못 본다.
input=$(cat)
case "$input" in
  *merge*) ;;
  *) exit 0 ;;
esac
HOOK_INPUT="$input" exec python3 - "$(cd "$(dirname "$0")" && pwd)" <<'PY'
import json, os, shlex, subprocess, sys

here = sys.argv[1]
try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    sys.exit(0)
if data.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''
lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
lex.whitespace_split = True
try:
    toks = list(lex)
except ValueError:
    sys.exit(0)

# `gh pr merge` 의 플래그 가운데 값을 받는 것(gh 2.92 의 `gh pr merge --help`)
MERGE_VALUED = {'-R', '--repo', '-t', '--subject', '-b', '--body', '-F', '--body-file',
                '--match-head-commit', '-A', '--author-email'}


def auto_merge(seg):
    """조각이 auto-merge 를 켜는 `gh pr merge` 면 (PR 번호 또는 '', 레포 또는 '')를, 아니면 None 을 돌려준다."""
    if seg[:3] != ['gh', 'pr', 'merge']:
        return None
    pos, repo, on, i = [], '', False, 3
    while i < len(seg):
        t = seg[i]
        i += 1
        if t == '--auto' or (t.startswith('--auto=') and t[7:].lower() not in ('false', '0')):
            on = True
        elif t in ('-R', '--repo'):
            repo, i = (seg[i] if i < len(seg) else ''), i + 1
        elif t.startswith('--repo='):
            repo = t[7:]
        elif t in MERGE_VALUED:
            i += 1
        elif not t.startswith('-'):
            pos.append(t)
    return (pos[0] if pos else '', repo) if on else None


segs, cur = [], []
for t in toks:
    if t and all(c in '();&|' for c in t):
        segs.append(cur)
        cur = []
    else:
        cur.append(t)
segs.append(cur)
found = next((r for r in map(auto_merge, segs) if r), None)
if not found:
    sys.exit(0)
pr, repo = found

script = os.path.join(here, 'wait_merge.sh')
top = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=data.get('cwd') or None,
                     capture_output=True, text=True).stdout.strip()
if top:
    rel = os.path.relpath(os.path.realpath(script), os.path.realpath(top))
    if not rel.startswith('..'):
        script = rel
run = 'bash %s %s%s' % (script, pr or '<PR 번호>', ' -R ' + repo if repo else '')
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": (
        "auto-merge 를 켰다. 지금 `%s` 를 Bash 의 run_in_background 로 실행한 뒤, Approve 를 부탁하는 블록으로 "
        "응답을 끝낸다%s. 대기 스크립트는 PR 이 머지되거나 사람이 봐야 할 일이 생기면 한 줄을 출력하고 끝나고, 그때 "
        "세션이 깨어난다 — 깨어나면 merge-pr 3절 「대기 스크립트가 끝나면」대로 한다."
        % (run, '' if pr else '(<PR 번호> 에 이 PR 의 번호를 넣는다)'))}}, ensure_ascii=False))
PY
