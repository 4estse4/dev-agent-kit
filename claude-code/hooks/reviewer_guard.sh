#!/usr/bin/env bash
# PreToolUse(Bash): 콜드 리뷰어(`agent_type` 이 `cold-reviewer`)의 GitHub 쓰기 · 푸시 · 새 Claude 세션을 막는다. 필요: python3
#
# **왜.** 리뷰어가 게시하지 않는 것은 정의의 「게시하지 마라. 호출자에게 돌려줘라」 절만 지켰다. 그 절이 근거로 드는
# 사고에서는 사람 승인 없이 코멘트 40건이 나갔고 그중 20건을 리뷰어가 올렸다. 리뷰어가 새 Claude 세션을 띄워 실험한
# 일도 있었다(이슈 #188). 설정 파일의 훅은 서브에이전트의 도구 호출에도 실행되고 입력에 `agent_type` 이 실린다(공식 문서
# hooks.md 「common input fields」). 그래서 이 훅은 리뷰어의 명령만 보고, 메인 세션과 다른 에이전트는 보지 않는다.
#
# **무엇을 막나.** 명령을 `;` · `&` · `|` · 괄호 · 줄바꿈에서 나눈 각 명령에서
# - `gh`: 읽는 하위 명령(`pr` 의 view · diff · checks · list · status, `issue` 의 view · list · status, `run` 의 view ·
#   list · watch, `repo view`, `release` · `workflow` 의 view · list, `label list`, `search`, `version` · `help`)이 아닌 것.
#   `gh api` 는 메서드가 GET 일 때만 통과한다 — `-X`/`--method` 를 주지 않았는데 `-f` · `-F` · `--field` ·
#   `--raw-field` · `--input` 이 있으면 gh 가 POST 로 보낸다
# - `git push`
# - `claude`(경로를 붙인 것 포함)
# 명령 앞의 `!` · `{` · 예약어(`if` · `then` · `do` 등), 변수 대입(`FOO=1`), `env` · `command` · `exec` · `nohup` · `time` ·
# `timeout <시간>`(경로를 붙인 것 포함)은 건너뛰고 본다.
#
# **heredoc 의 본문은 셸이 받을 때만 명령으로 본다.** 리뷰어는 `Write` 를 못 써서 스크래치 스크립트를 heredoc 으로
# 쓴다(`cat > 파일 <<EOF`). 그 본문은 실행되는 명령이 아니라 보지 않고, 그 스크립트를 실행하면 이 훅은 안을 보지 않는다
# (아래). heredoc 을 받는 명령 · 묶음(`{ …; }` · `( … )`)이나 같은 파이프의 그 뒤 명령이 표준입력을 명령으로 실행하면
# 본문이 그대로 실행되므로 본문 줄도 명령으로 본다. 셸(`bash` · `sh` · `zsh` · `dash` · `ksh`, 경로를 붙인 것 포함)과
# `source` · `.` 로 `/dev/stdin` 을 읽는 명령이 그렇다(`bash <<'EOF'` · `cat <<'EOF' | bash` · `test … || bash <<EOF` ·
# `{ bash; } <<EOF` · `source /dev/stdin <<EOF`). 여는 줄이 `|` · `&&` · `||` 로 끝나면 명령이 본문 뒤의 줄로 이어지므로
# 그 줄까지 붙여 판정한다(`cat <<EOF |` · 본문 · `EOF` · `bash`). heredoc 은 bash 가 닫는 자리에서 닫는다 — 끝말은 낱말
# 전체에서 따옴표 · `\` 를 뗀 것이다(`<<E-1` · `<<\EOF` · `<<E"O"F` 는 `EOF`). 따옴표 · 주석 안의 `<<` 는 heredoc 이
# 아니다. 한때 본문을 늘 보지 않아 셸이 받은 게시 명령이 통과했고, 그다음엔 `||` 뒤 · `!` · 묶음 · `source` 로 받은 것,
# 끝말을 다르게 읽은 것, 본문 뒤로 이어지는 파이프가 남았다. 사람이 PR 을 열기 전에 세 번 짚었다.
#
# **판정 못 하면 막는다.** 훅 입력을 못 읽음 · 따옴표가 닫히지 않아 명령을 나누지 못함 · heredoc 의 끝말을 읽지 못하거나
# 끝말 줄 없이 끝남(어디서 닫히는지 모르면 뒤의 줄이 명령인지도 모른다).
#
# **무엇을 못 막나.** 형식대로 입력한 명령의 실수를 막는다. 명령 이름을 꾸민 것(변수 · 별칭 · 낱말 안의 따옴표나 `\`),
# 스크립트 파일 안의 명령, `bash -c` · `eval` 안의 명령, 셸에 here-string(`<<<`)으로 준 명령, 다른 명령의 인자로 실행되는
# 명령(`xargs` · `find -exec`), 인라인 인터프리터가 실행하는 명령은 못 막는다. 부른 세션의 체크아웃에서 ref 를 바꾸는
# 명령(`git fetch` · `checkout` · `commit`)은 보지 않는다 — 명령이 어느 레포를 가리키는지 가리려면 `cd` · `-C` 를 풀어야
# 한다. 그 길은 정의의 「실험할 자리」 절이 막는다.
input=$(cat)
case "$input" in
  *cold-reviewer*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, re, shlex, sys

READ = {
    'pr': {'view', 'diff', 'checks', 'list', 'status'},
    'issue': {'view', 'list', 'status'},
    'run': {'view', 'list', 'watch'},
    'repo': {'view'},
    'release': {'view', 'list'},
    'workflow': {'view', 'list'},
    'label': {'list'},
}
WRAPPERS = {'env', 'command', 'exec', 'nohup', 'time', 'timeout'}
# 명령 앞에 와도 명령이 아닌 낱말 — 부정 · 묶음 · 예약어
LEADERS = {'!', '{', 'if', 'then', 'else', 'elif', 'while', 'until', 'do'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
STDIN = {'/dev/stdin', '/dev/fd/0'}
CONTROL = set(';&|()\n')


def deny(why):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": why}}, ensure_ascii=False))
    sys.exit(0)


try:
    data = json.loads(os.environ['HOOK_INPUT'])
except ValueError:
    deny("리뷰어 가드가 훅 입력을 읽지 못해 명령을 막았다.")
if data.get('agent_type') != 'cold-reviewer':
    sys.exit(0)
cmd = (data.get('tool_input') or {}).get('command') or ''


def base(word):
    return word.rsplit('/', 1)[-1]


def head(words):
    """명령 앞의 부정 · 묶음 · 예약어, 변수 대입, 감싸는 명령(경로를 붙인 env · timeout <시간> 등)을 건너뛴 낱말들."""
    w = list(words)
    while w:
        if w[0] in LEADERS or re.match(r'[A-Za-z_][A-Za-z0-9_]*=', w[0]):
            w.pop(0)
        elif base(w[0]) in WRAPPERS:
            name = base(w.pop(0))
            while w and (w[0].startswith('-') or re.match(r'[A-Za-z_][A-Za-z0-9_]*=', w[0])):
                w.pop(0)
            if name == 'timeout' and w:
                w.pop(0)          # 시간
        else:
            break
    return w


def runs_stdin(words):
    """이 단순 명령이 표준입력을 명령으로 실행하나 — 셸이거나, source · . 로 표준입력을 읽는다."""
    w = head(words)
    if not w:
        return False
    return base(w[0]) in SHELLS or (w[0] in ('source', '.') and any(a in STDIN for a in w[1:]))


def parse(tokens, i=0, closer=None):
    """tokens[i:] 를 closer(`}` · `)`)까지 읽어 (파이프라인 목록, 다음 위치) 를 낸다. 파이프라인은 단위의 목록이고,
    단위는 단순 명령(words)이나 묶음(group, 안의 파이프라인 목록)이며 heredoc 을 받는지(takes)를 든다."""
    pipes, pipe = [], []
    unit = {'words': [], 'group': None, 'takes': False}

    def push():
        nonlocal unit
        if unit['words'] or unit['group'] is not None:
            pipe.append(unit)
        unit = {'words': [], 'group': None, 'takes': False}

    while i < len(tokens):
        t = tokens[i]
        if (t == ')' and closer == ')') or (t == '}' and closer == '}' and not unit['words']):
            push()
            pipes.append(pipe)
            return pipes, i + 1
        if t in ('(', '{') and not unit['words'] and unit['group'] is None:
            sub, i = parse(tokens, i + 1, ')' if t == '(' else '}')
            unit['group'] = sub
            continue
        if t in ('|', '|&'):
            push()
        elif t and set(t) <= set(';&|()'):
            push()
            pipes.append(pipe)
            pipe = []
        elif t.startswith('<<') and not t.startswith('<<<'):
            unit['takes'] = True
            i += 1                # 끝말
        elif t and set(t) <= set('<>&'):
            i += 1                # 리다이렉트 뒤의 파일 이름
        elif unit['group'] is None:
            unit['words'].append(t)
        i += 1
    push()
    pipes.append(pipe)
    return pipes, i


def shellish(unit):
    if unit['group'] is not None:
        return any(shellish(u) for p in unit['group'] for u in p)
    return runs_stdin(unit['words'])


def feeds(pipes):
    for p in pipes:
        for k, u in enumerate(p):
            if u['takes'] and any(shellish(v) for v in p[k:]):
                return True
            if u['group'] is not None and feeds(u['group']):
                return True
    return False


def feeds_shell(line):
    """heredoc 을 여는 줄에서, heredoc 을 받는 명령 · 묶음이나 같은 파이프의 그 뒤 명령이 표준입력을 명령으로 실행하나.
    나누지 못하면 그렇다고 본다."""
    lex = shlex.shlex(line, posix=True, punctuation_chars=';&|()<>')
    lex.whitespace = ' \t\r'
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        return True
    return feeds(parse(tokens)[0])


def heredocs(line):
    """여는 줄에서 따옴표 · 주석 밖의 heredoc 들을 (앞 탭을 떼나, 끝말) 로 낸다. `<<<`(here-string)는 heredoc 이 아니다.
    끝말은 bash 처럼 낱말 전체에서 따옴표와 `\\` 를 뗀 것이다(`<<E"O"F` 는 `EOF`). 끝말을 읽지 못하면 ValueError."""
    out, i, n, q = [], 0, len(line), None
    while i < n:
        c = line[i]
        if q:
            if c == q:
                q = None
            elif c == '\\' and q == '"':
                i += 1
            i += 1
            continue
        if c in '\'"':
            q = c
        elif c == '\\':
            i += 1
        elif c == '#' and (i == 0 or line[i - 1] in ' \t;&|('):
            break                 # 주석
        elif line.startswith('<<', i) and not line.startswith('<<<', i) and (i == 0 or line[i - 1] != '<'):
            i += 2
            tabs = i < n and line[i] == '-'
            i += 1 if tabs else 0
            while i < n and line[i] in ' \t':
                i += 1
            word, wq = [], None
            while i < n:
                c = line[i]
                if wq:
                    if c == wq:
                        wq = None
                    else:
                        word.append(c)
                elif c in '\'"':
                    wq = c
                elif c == '\\' and i + 1 < n:
                    i += 1
                    word.append(line[i])
                elif c in ' \t;&|<>()':
                    break
                else:
                    word.append(c)
                i += 1
            if wq or not word:
                raise ValueError(line)
            out.append((tabs, ''.join(word)))
            continue
        i += 1
    return out


def drop_heredocs(text):
    """heredoc 본문 줄을 뺀다. 여는 줄과 그 뒤의 명령은 남긴다. 셸이 받는 heredoc 은 본문이 실행되므로 남긴다.
    여는 줄이 `|` · `&&` · `||` 로 끝나면 명령은 본문 뒤의 줄로 이어지므로 그 줄까지 붙여 판정한다. 끝말 줄 없이 끝나면
    어디서 닫히는지 모르므로 ValueError."""
    lines = text.split('\n')
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        bodies = []
        for tabs, word in heredocs(line):
            while i < len(lines) and (lines[i].lstrip('\t') if tabs else lines[i]) != word:
                bodies.append(lines[i])
                i += 1
            if i >= len(lines):
                raise ValueError(word)
            i += 1                # 끝말 줄
        if not bodies:
            continue
        whole = line
        if re.search(r'(\||&&)\s*$', line) and i < len(lines):
            whole = line + ' ' + lines[i]
        if feeds_shell(whole):
            out.extend(bodies)
    return '\n'.join(out)


try:
    text = drop_heredocs(cmd)
except ValueError:
    deny("리뷰어 가드가 heredoc 의 끝말이나 닫는 줄을 찾지 못해 판정하지 못했다. 콜드 리뷰어의 명령이라 막았다.")
lex = shlex.shlex(text, posix=True, punctuation_chars=';&|()<>\n')
lex.whitespace = ' \t\r'
lex.whitespace_split = True
try:
    tokens = list(lex)
except ValueError:
    deny("리뷰어 가드가 명령을 나누지 못했다(따옴표가 닫히지 않았다). 콜드 리뷰어의 명령이라 막았다.")

commands, cur, skip_next = [], [], False
for t in tokens:
    if skip_next:
        skip_next = False
        continue
    if t and set(t) <= CONTROL:
        commands.append(cur)
        cur = []
    elif t and set(t) <= set('<>&'):
        skip_next = True          # 리다이렉트 뒤의 파일 이름
    else:
        cur.append(t)
commands.append(cur)


def why(words):
    w = head(words)
    if not w:
        return None
    name = os.path.basename(w[0])
    if name == 'claude':
        return '새 Claude 세션을 띄운다'
    if name == 'git':
        i = 1
        while i < len(w) and w[i].startswith('-'):
            i += 2 if w[i] in ('-C', '-c', '--git-dir', '--work-tree', '--namespace') else 1
        return '푸시한다' if i < len(w) and w[i] == 'push' else None
    if name != 'gh':
        return None
    rest, i = [], 1
    while i < len(w):
        if w[i] in ('-R', '--repo'):
            i += 2
            continue
        if w[i].startswith('--repo='):
            i += 1
            continue
        rest.append(w[i])
        i += 1
    if not rest or rest[0] in ('version', 'help', '--version', '--help', '-h', 'search'):
        return None
    group, args = rest[0], rest[1:]
    if group == 'api':
        method, body = None, False
        j = 0
        while j < len(args):
            a = args[j]
            if a in ('-X', '--method') and j + 1 < len(args):
                method = args[j + 1]
                j += 2
                continue
            if a.startswith('--method='):
                method = a.split('=', 1)[1]
            elif a.startswith('-X') and len(a) > 2:
                method = a[2:]
            elif a in ('-f', '-F', '--field', '--raw-field', '--input') or re.match(r'(-f|-F).|--(raw-)?field=|--input=', a):
                body = True
            j += 1
        method = (method or ('POST' if body else 'GET')).upper()
        return None if method == 'GET' else 'GitHub 에 쓴다(gh api %s)' % method
    sub = next((a for a in args if not a.startswith('-')), '')
    if sub in READ.get(group, ()):
        return None
    return 'GitHub 에 쓰거나 부른 세션의 체크아웃을 바꾸는 gh 명령이다(gh %s %s)' % (group, sub)


for words in commands:
    reason = why(words)
    if reason:
        deny("콜드 리뷰어의 명령을 막았다 — %s: `%s`. 리뷰어는 게시하지 않고, 푸시하지 않고, 새 세션을 띄우지 않는다"
             "(cold-reviewer.md 「게시하지 마라. 호출자에게 돌려줘라」). 그것이 있어야 확인되는 것은 보고의 「확인 못 한 것」에 "
             "적어 부른 쪽이 사람에게 묻게 한다." % (reason, ' '.join(words)))
PY
