#!/usr/bin/env bash
# SessionStart · PreToolUse(Bash): 킷의 git 훅이 꺼진 레포에서 세션 시작 때 그것을 알리고, 꺼진 동안
# `git commit` · `git push` 를 막는다. 필요: python3 · git
#
# **왜.** 훅 파일은 `.kit/git-hooks/` 에 커밋되어 clone 을 따라오지만, 그것을 켜는 `core.hooksPath` 는
# `.git/config` 에 있어 clone 에 담기지 않는다 — git 이 일부러 그렇게 만들었고 피할 길이 없다. 그래서 clone 한
# 레포에서 일하는 세션은 훅이 꺼진 줄 모른 채 커밋 · 푸시했고, 커밋 전 검사(보호 브랜치 · 시크릿 · 게이트)가
# 막았어야 할 것이 CI 에서야 드러났다. 세션 시작 알림은 세션이 읽고 따라야 지켜지므로, 켜기 전에는 커밋과
# 푸시를 막는다. 켤지는 사람이 정한다 — 세션은 알림을 받으면 사람에게 묻고, 고르면 켠다. 켜지 않기로 하면 세션은
# 그 레포에서 커밋 · 푸시하지 않고, 사람이 세션 밖 터미널에서 한다.
#
# **꺼졌다고 보는 것.** 레포 루트에 `.kit/git-hooks/` 가 있는데 `core.hooksPath` 가 없거나 그 디렉터리가 아닐
# 때다. 상대 경로는 레포 루트 기준으로 푼다. `.kit/git-hooks/` 가 없는 레포(킷의 git 훅을 설치하지 않은 레포)
# 에서는 아무것도 하지 않는다.
#
# **어느 레포를 보나.** 세션을 연 프로젝트의 레포뿐이다 — 같은 git 공통 디렉터리를 쓰는 worktree 를 포함한다.
# 명령의 `git -C <경로>` 가 있으면 그 경로의 레포를, 없으면 명령을 입력한 디렉터리의 레포를 그 레포와 견준다.
# 프로젝트 밖에 실험하려고 만든 clone 은 프로젝트의 커밋이 아니라 보지 않는다.
#
# **무엇을 못 막나.** 명령 글자로 알아보므로 스크립트 파일 안의 `git commit` 은 못 보고, `git -C "$d"` 처럼 경로를
# 셸 변수로 준 명령은 그 경로를 풀지 못해 판정하지 않는다. 한 명령 안에서 `cd` 로 다른 디렉터리에 들어가 입력한
# 커밋은 처음 디렉터리로 판정하고, `git -c core.hooksPath=…` 로 그 명령에만 준 설정은 보지 않는다. 판정하지
# 못하면(레포가 아니거나 git 이 실패하면) 막지 않는다. 이 훅은 켜는 것을 잊은 경우를 막는 것이고, 작정한 우회를
# 막는 것은 CI 와 브랜치 보호다.
input=$(cat)
# PreToolUse 는 모든 Bash 호출마다 실행되므로 git 이 없으면 파이썬을 실행하지 않고 끝낸다.
case "$input" in
  *SessionStart*|*git*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" python3 - <<'PY'
import json, os, re, shlex, subprocess, sys

ENABLE = 'git config core.hooksPath .kit/git-hooks'
DECLINE = '켜지 않기로 하면 이 레포에서는 커밋 · 푸시하지 않고, 사람이 세션 밖 터미널에서 합니다.'
try:
    data = json.loads(os.environ.get('HOOK_INPUT') or '{}')
except ValueError:
    sys.exit(0)


def git(d, *args):
    """(종료 코드, 출력). git 을 실행하지 못하면 (None, '')"""
    try:
        r = subprocess.run(['git', '-C', d] + list(args), capture_output=True, text=True)
    except OSError:
        return None, ''
    return r.returncode, r.stdout.strip()


def common(d):
    rc, out = git(d, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    return os.path.realpath(out) if rc == 0 and out else None


PROJECT = common(os.environ.get('CLAUDE_PROJECT_DIR') or data.get('cwd') or '.')


def off(d):
    """d 가 프로젝트의 레포이고 킷의 git 훅을 꺼 두었으면 (레포 루트, 지금 값) 을, 아니거나 판정하지 못하면 None"""
    if PROJECT is None or common(d) != PROJECT:
        return None
    rc, top = git(d, 'rev-parse', '--show-toplevel')
    if rc != 0 or not top:
        return None
    want = os.path.join(top, '.kit', 'git-hooks')
    if not os.path.isdir(want):
        return None
    rc, v = git(top, 'config', '--get', 'core.hooksPath')
    if rc not in (0, 1):  # 1 은 설정이 없다는 뜻이다. 그 밖은 판정하지 못한 것이다
        return None
    if v:
        p = os.path.expanduser(v)
        if not os.path.isabs(p):
            p = os.path.join(top, p)
        if os.path.realpath(p) == os.path.realpath(want):
            return None
    return top, v


if data.get('hook_event_name') == 'SessionStart':
    s = off(os.environ.get('CLAUDE_PROJECT_DIR') or data.get('cwd') or '.')
    if s:
        print('dev-agent-kit: 이 레포는 킷의 git 훅이 꺼져 있습니다(core.hooksPath: %s). 커밋 · 푸시 전 검사가 '
              '실행되지 않고, 켜기 전에는 에이전트 훅이 git commit · git push 를 막습니다. 사람에게 켤지 묻고, '
              '고르면 레포 루트에서 이 명령으로 켭니다: %s. %s' % (s[1] or '없음', ENABLE, DECLINE))
    sys.exit(0)

cmd = (data.get('tool_input') or {}).get('command') or ''
cwd = data.get('cwd') or os.getcwd()
# `git` 다음에 전역 옵션만 오고 그다음 낱말이 commit · push 인 것. 값을 따로 받는 전역 옵션(`-C` · `-c` ·
# `--git-dir` · `--work-tree` · `--namespace` · `--config-env`)만 다음 낱말을 값으로 읽는다 — 다른 옵션까지 값을
# 받게 하면 `git --no-pager log --grep commit` 의 `log` 를 값으로 읽어 commit 을 하위 명령으로 본다. 따옴표 ·
# `bash -c` 안이어도 찾는다. `commit-tree` 처럼 이어진 낱말은 아니다.
CALL = re.compile(r'(?<![\w.-])["\']?(?:[^\s"\';&|()]*/)?git["\']?'
                  r'((?:\s+(?:(?:-C|-c|--git-dir|--work-tree|--namespace|--config-env)\s+[^\s;&|]+|-[^\s;&|]+))*)'
                  r'\s+["\']?(commit|push)["\']?(?![\w-])')
for m in CALL.finditer(cmd):
    d = cwd
    try:
        opts = shlex.split(m.group(1))
    except ValueError:
        opts = m.group(1).split()
    for i, o in enumerate(opts):
        if o == '-C' and i + 1 < len(opts):
            d = os.path.join(d, os.path.expanduser(opts[i + 1]))
    s = off(d)
    if not s:
        continue
    sub = m.group(2)
    why = ('이 레포(%s)는 킷의 git 훅이 꺼져 있어(core.hooksPath: %s) git %s %s 막습니다. 켜기 전에는 커밋 전 '
           '검사(보호 브랜치 · 시크릿 · 게이트)가 실행되지 않습니다. 사람에게 켤지 묻고, 고르면 레포 루트에서 이 '
           '명령으로 켠 뒤 다시 입력합니다: %s. %s'
           % (s[0], s[1] or '없음', sub, '을' if sub == 'commit' else '를', ENABLE, DECLINE))
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': why}}, ensure_ascii=False))
    sys.exit(0)
PY
exit 0
