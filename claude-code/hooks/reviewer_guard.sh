#!/usr/bin/env bash
# PreToolUse(Bash): 콜드 리뷰어(`agent_type` 이 `cold-reviewer`)의 GitHub 쓰기 · 푸시 · 새 Claude 세션을 막는다. 필요: python3
#
# **왜.** 리뷰어가 게시하지 않는 것은 정의의 「게시하지 마라. 호출자에게 돌려줘라」 절만 지켰다. 그 절이 근거로 드는
# 사고에서는 사람 승인 없이 코멘트 40건이 나갔고 그중 20건을 리뷰어가 올렸다. 리뷰어가 새 Claude 세션을 띄워 실험한
# 일도 있었다(이슈 #188). 설정 파일의 훅은 서브에이전트의 도구 호출에도 실행되고 입력에 `agent_type` 이 실린다(공식 문서
# hooks.md 「common input fields」). 그래서 이 훅은 리뷰어의 명령만 보고, 메인 세션과 다른 에이전트는 보지 않는다.
#
# **무엇을 막나.** 명령을 bash 처럼 읽어 실행될 각 명령에서
# - `gh`: 읽는 하위 명령(`pr` 의 view · diff · checks · list · status, `issue` 의 view · list · status, `run` 의 view ·
#   list · watch, `repo view`, `release` · `workflow` 의 view · list, `label list`, `search`, `version` · `help`)이 아닌 것.
#   `gh api` 는 메서드가 GET 일 때만 통과한다 — `-X`/`--method` 를 주지 않았는데 `-f` · `-F` · `--field` ·
#   `--raw-field` · `--input` 이 있으면 gh 가 POST 로 보낸다
# - `git push`
# - `claude`(경로를 붙인 것 포함)
# 명령 앞의 `!` · 예약어(`if` · `then` · `do` · `coproc` 등), 변수 대입(`FOO=1`), `env` · `command` · `exec` · `nohup` ·
# `time` · `timeout <시간>`(경로를 붙인 것 포함)은 건너뛰고 본다.
#
# **bash 처럼 읽는다.** 입력 전체를 한 번에 읽는다 — 낱말의 따옴표(`$'…'` · `$"…"` 포함) · `\` 를 떼고, 주석을 빼고, `\` 줄
# 잇기를 붙이고, `;` · `&` · `|` · `&&` · `||` · 줄바꿈에서 명령을 나누고, `{ …; }` · `( … )` 묶음 안을 읽는다(예약어 ·
# `time` · `function 이름` · `coproc 이름` 뒤의 묶음 포함). `|` · `&&` · `||` 뒤의 빈 줄과 주석 줄은 bash 처럼 건너뛰어 같은
# 명령으로 잇는다. 명령 치환(`$( … )` · 백틱)과 프로세스 치환(`<( … )` · `>( … )`) 안도 명령으로 읽는다 — 큰따옴표 안의
# 것도 같다. heredoc 본문은 그 줄의 줄바꿈 다음에서 읽고, 끝말은 bash 처럼 낱말 전체에서 따옴표 · `\` 를 뗀 것이다
# (`<<E-1` · `<<\EOF` · `<<E"O"F`). 한때 heredoc 을 줄 단위로 다뤄 `||` 뒤 · `!` · 묶음 · `source` 로 셸이 받은 것, 끝말을
# 다르게 읽은 것, 본문 뒤로 이어지는 파이프가 차례로 통과했다. 사람이 PR 을 열기 전에 네 번 짚었다.
#
# **heredoc 본문은 셸이 받을 때만 명령으로 본다.** 리뷰어는 `Write` 를 못 써서 스크래치 스크립트를 heredoc 으로
# 쓴다(`cat > 파일 <<'EOF'`). 그 본문은 실행되는 명령이 아니라 보지 않고, 그 스크립트를 실행하면 이 훅은 안을 보지 않는다
# (아래). heredoc · here-string(`<<<`)을 받는 명령 · 묶음이나 같은 파이프의 그 뒤 명령(묶음 밖으로 이어지는 것 포함)이
# 표준입력을 명령으로 실행하면 본문이 그대로 실행되므로 본문도 명령으로 본다. 셸(`bash` · `sh` · `zsh` · `dash` · `ksh`,
# 경로를 붙인 것 포함)과 `source` · `.` 로 `/dev/stdin` 을 읽는 명령이 그렇다. 프로세스 치환 안의 heredoc 본문은 늘 명령으로
# 본다 — 셸이 그 출력을 스크립트 파일로 읽을 수 있다(`bash <(cat <<'EOF' …)`). 출력을 셸에 보내는 프로세스 치환
# (`> >(bash)` · `exec > >(bash)`)이 있으면 모든 heredoc 본문을 명령으로 본다. 끝말에 따옴표 · `\` 가 없으면 셸이 본문을
# 펼치므로 본문의 명령 치환도 명령으로 본다.
#
# **판정 못 하면 막는다.** 훅 입력을 못 읽음 · 따옴표 · 백틱 · 치환이 닫히지 않음 · heredoc 의 끝말을 읽지 못하거나 끝말 줄
# 없이 끝남 · `|` · `&&` · `||` 뒤에 명령 없이 끝남 · 읽다가 예외로 멈춤(치환을 깊이 겹친 것 등. 훅이 예외로 끝나면 명령이
# 실행된다). 어디까지가 명령인지 모르면 뒤의 글이 명령인지도 모른다.
#
# **무엇을 못 막나.** 형식대로 입력한 명령의 실수를 막는다. 명령 이름을 꾸민 것(변수 · 별칭 · 글롭 · 중괄호 확장 · 명령
# 치환이 낸 이름), 셸이 heredoc · here-string 이 아닌 글을 실행하는 것(스크립트 파일 · `echo … | bash` 처럼 다른 명령의
# 출력 · FIFO), `bash -c` · `eval` 안의 명령, 다른 명령의 인자로 실행되는 명령(`xargs` · `find -exec` · `nice` 등), 인라인
# 인터프리터가 실행하는 명령은 못 막는다. Claude Code 는 사용자의 셸로 명령을 실행하는데, zsh 가 bash 와 다르게 읽는
# 꼴(`=gh` · 글롭 한정자 등)은 따라가지 않는다. 부른 세션의 체크아웃에서 ref 를 바꾸는 명령(`git fetch` · `checkout` ·
# `commit`)은 보지 않는다 — 명령이 어느 레포를 가리키는지 가리려면 `cd` · `-C` 를 풀어야 한다. 그 길은 정의의 「실험할
# 자리」 절이 막는다.
input=$(cat)
case "$input" in
  *cold-reviewer*) ;;
  *) exit 0 ;;
esac

HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import json, os, re, sys

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
# 명령 앞에 와도 명령이 아닌 낱말 — 부정 · 예약어. 묶음(`{` · `(`)은 parse 가 읽는다
LEADERS = {'!', 'if', 'then', 'else', 'elif', 'while', 'until', 'do', 'coproc'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
STDIN = {'/dev/stdin', '/dev/fd/0'}
# 긴 것부터 찾는다
OPS = ('<<<', '&>>', ';;&', '<<-', '<<', '>>', '<&', '>&', '&>', '>|', '<>', '&&', '||', '|&', ';;', ';&',
       '<', '>', ';', '&', '|', '(', ')')
REDIRECTS = {'<<<', '&>>', '>>', '<&', '>&', '&>', '>|', '<>', '<', '>'}
ANSI = {'a': '\a', 'b': '\b', 'e': '\x1b', 'E': '\x1b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
        '\\': '\\', "'": "'", '"': '"', '?': '?'}


class Unreadable(Exception):
    """명령을 bash 처럼 읽지 못했다 — 어디까지가 명령인지 모른다."""


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
    """명령 앞의 부정 · 예약어, 변수 대입, 감싸는 명령(경로를 붙인 env · timeout <시간> 등)을 건너뛴 낱말들."""
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


def lex(text, i, stop, subs):
    """text[i:] 를 bash 처럼 토큰으로 나눈다 — ('w', 낱말) · ('o', 연산자) · ('n', None) · ('h', heredoc). 낱말은 따옴표와
    `\\` 를 떼고, 주석과 `\\` 줄 잇기는 뺀다. heredoc 본문은 그 줄의 줄바꿈 다음에서 읽어 heredoc 에 붙인다. 명령 치환 ·
    프로세스 치환 · 백틱 안은 따로 나눠 subs 에 (토큰, 여는 글자) 로 더한다 — 명령 치환과 백틱은 `$`, 프로세스 치환은 `<` ·
    `>`. stop 이면 짝이 없는 `)` 다음에서 멈춘다. (토큰, 다음 위치) 를 낸다."""
    toks, pending, depth, n = [], [], 0, len(text)
    word, inword = [], False

    def end():
        nonlocal word, inword
        if inword:
            toks.append(('w', ''.join(word)))
        word, inword = [], False

    while i < n:
        c = text[i]
        if c == '\\':
            if text.startswith('\n', i + 1):
                i += 2            # 줄 잇기
                continue
            word.append(text[i + 1:i + 2])
            inword, i = True, i + 2
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise Unreadable('따옴표가 닫히지 않았다')
            word.append(text[i + 1:j])
            inword, i = True, j + 1
        elif c == '"' or text.startswith('$"', i):
            i = dquote(text, i + (1 if c == '"' else 2), word, subs)
            inword = True
        elif text.startswith("$'", i):
            i = ansi(text, i + 2, word)
            inword = True
        elif c == '`':
            i = backtick(text, i + 1, subs)
            inword = True
        elif text.startswith('$(', i) or (not inword and text[i:i + 2] in ('<(', '>(')):
            inner, i = lex(text, i + 2, True, subs)
            subs.append((inner, c))
            inword = True
        elif c == '#' and not inword:
            j = text.find('\n', i)
            i = n if j < 0 else j  # 주석
        elif c in ' \t\r':
            end()
            i += 1
        elif c == '\n':
            end()
            toks.append(('n', None))
            i += 1
            for doc in pending:
                i = body(text, i, doc)
            pending = []
        else:
            op = next((o for o in OPS if text.startswith(o, i)), None)
            if op is None:
                word.append(c)
                inword, i = True, i + 1
                continue
            end()
            i += len(op)
            if op == ')' and stop and depth == 0:
                if pending:
                    raise Unreadable('heredoc 의 끝말 줄이 없다')
                return toks, i
            depth += 1 if op == '(' else -1 if op == ')' else 0
            if op in ('<<', '<<-'):
                doc = {'tabs': op == '<<-'}
                i = delimiter(text, i, doc)
                pending.append(doc)
                toks.append(('h', doc))
            else:
                toks.append(('o', op))
    end()
    if stop:
        raise Unreadable('명령 치환이 닫히지 않았다')
    if pending:
        raise Unreadable('heredoc 의 끝말 줄이 없다')
    return toks, i


def dquote(text, i, word, subs):
    """큰따옴표 안을 읽어 word 에 더하고 닫는 따옴표 다음 위치를 낸다. 안의 명령 치환 · 백틱은 subs 에 더한다."""
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            return i + 1
        if c == '\\' and i + 1 < n and text[i + 1] in '$`"\\\n':
            if text[i + 1] != '\n':
                word.append(text[i + 1])
            i += 2
        elif text.startswith('$(', i):
            inner, i = lex(text, i + 2, True, subs)
            subs.append((inner, '$'))
        elif c == '`':
            i = backtick(text, i + 1, subs)
        else:
            word.append(c)
            i += 1
    raise Unreadable('따옴표가 닫히지 않았다')


def ansi(text, i, word):
    """`$'…'` 안을 bash 처럼 풀어 word 에 더하고 닫는 따옴표 다음 위치를 낸다(`$'g\\x68'` 은 `gh`)."""
    n = len(text)
    while i < n:
        c = text[i]
        if c == "'":
            return i + 1
        m = re.match(r'\\(?:x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|U([0-9A-Fa-f]{1,8})|([0-7]{1,3}))', text[i:])
        if m:
            code = int(m.group(4), 8) if m.group(4) else int(next(g for g in m.groups() if g), 16)
            word.append(chr(code) if code <= 0x10FFFF else '')
            i += m.end()
        elif c == '\\' and i + 1 < n:
            word.append(ANSI.get(text[i + 1], c + text[i + 1]))
            i += 2
        else:
            word.append(c)
            i += 1
    raise Unreadable('따옴표가 닫히지 않았다')


def backtick(text, i, subs):
    """백틱 안을 명령으로 나눠 subs 에 더하고 닫는 백틱 다음 위치를 낸다."""
    out, n = [], len(text)
    while i < n:
        c = text[i]
        if c == '`':
            subs.append((lex(''.join(out), 0, False, subs)[0], '$'))
            return i + 1
        if c == '\\' and i + 1 < n and text[i + 1] in '`$\\':
            out.append(text[i + 1])
            i += 2
        else:
            out.append(c)
            i += 1
    raise Unreadable('백틱이 닫히지 않았다')


def delimiter(text, i, doc):
    """`<<` 뒤의 끝말을 읽어 doc 에 적고 다음 위치를 낸다. bash 처럼 낱말 전체에서 따옴표와 `\\` 를 떼고(`<<E"O"F` 는
    `EOF`), 그중 하나라도 있었으면 셸이 본문을 펼치지 않는다."""
    n = len(text)
    while i < n and text[i] in ' \t':
        i += 1
    word, quoted, start = [], False, i
    while i < n and text[i] not in ' \t\n;&|<>()':
        c = text[i]
        if c in '\'"':
            j = text.find(c, i + 1)
            if j < 0:
                raise Unreadable('heredoc 의 끝말을 읽지 못했다')
            word.append(text[i + 1:j])
            quoted, i = True, j + 1
        elif c == '\\' and i + 1 < n:
            word.append(text[i + 1])
            quoted, i = True, i + 2
        else:
            word.append(c)
            i += 1
    if i == start:
        raise Unreadable('heredoc 의 끝말을 읽지 못했다')
    doc['word'], doc['quoted'] = ''.join(word), quoted
    return i


def body(text, i, doc):
    """줄바꿈 다음(i)부터 끝말 줄까지를 heredoc 본문으로 읽어 doc 에 붙이고 끝말 줄 다음 위치를 낸다. `<<-` 는 줄 앞의 탭을
    떼고 끝말과 대조한다."""
    lines, n = [], len(text)
    while i < n:
        j = text.find('\n', i)
        line, i = (text[i:], n) if j < 0 else (text[i:j], j + 1)
        if (line.lstrip('\t') if doc['tabs'] else line) == doc['word']:
            doc['body'] = '\n'.join(lines)
            return i
        lines.append(line)
    raise Unreadable('heredoc 의 끝말 줄이 없다')


def expansions(text, subs):
    """끝말에 따옴표가 없는 heredoc 본문은 셸이 펼친다 — 본문의 명령 치환 · 백틱을 subs 에 더한다."""
    i, n = 0, len(text)
    while i < n:
        if text[i] == '\\':
            i += 2
        elif text.startswith('$(', i):
            inner, i = lex(text, i + 2, True, subs)
            subs.append((inner, '$'))
        elif text[i] == '`':
            i = backtick(text, i + 1, subs)
        else:
            i += 1


def parse(toks, i=0, closer=None):
    """토큰을 closer(`}` · `)`)까지 읽어 (파이프라인 목록, 다음 위치) 를 낸다. 파이프라인은 단위의 목록이고, 단위는 단순
    명령(words)이나 묶음(group, 안의 파이프라인 목록)이며 표준입력으로 받는 heredoc · here-string 을 stdin 에 든다.
    `|` · `&&` · `||` 뒤의 줄바꿈은 bash 처럼 건너뛴다. 묶음은 명령 앞(예약어 · `time` 뒤와 `function 이름` ·
    `coproc 이름` 뒤 포함)에서 시작한다."""
    pipes, pipe = [], []
    unit = {'words': [], 'group': None, 'stdin': []}

    def push():
        nonlocal unit
        if unit['words'] or unit['group'] is not None or unit['stdin']:
            pipe.append(unit)
        unit = {'words': [], 'group': None, 'stdin': []}

    while i < len(toks):
        kind, v = toks[i]
        i += 1
        if (closer == ')' and (kind, v) == ('o', ')')) or (closer == '}' and (kind, v) == ('w', '}') and not unit['words']):
            push()
            pipes.append(pipe)
            return pipes, i
        w = unit['words']
        starts = all(x in LEADERS or x in ('time', '-p') for x in w) or (len(w) == 2 and w[0] in ('function', 'coproc'))
        if (kind, v) in (('o', '('), ('w', '{')) and starts and unit['group'] is None:
            unit['group'], i = parse(toks, i, ')' if v == '(' else '}')
        elif kind == 'o' and v in ('|', '|&', '&&', '||'):
            push()
            if v in ('&&', '||'):
                pipes.append(pipe)
                pipe = []
            while i < len(toks) and toks[i][0] == 'n':
                i += 1
            if i == len(toks):
                raise Unreadable('`%s` 뒤에 명령이 없다' % v)
        elif kind == 'n' or (kind == 'o' and v not in REDIRECTS):
            push()
            pipes.append(pipe)
            pipe = []
        elif kind == 'h':
            unit['stdin'].append(v)
        elif kind == 'o':
            if v == '<<<' and i < len(toks) and toks[i][0] == 'w':
                unit['stdin'].append({'body': toks[i][1], 'quoted': True})
            i += 1                # 리다이렉트 대상
        elif unit['group'] is None:
            unit['words'].append(v)
    push()
    pipes.append(pipe)
    return pipes, i


def shellish(unit):
    if unit['group'] is not None:
        return any(shellish(u) for p in unit['group'] for u in p)
    return runs_stdin(unit['words'])


def walk(pipes, out, subs, downstream=False):
    """단순 명령을 out 에 모은다. 단위가 표준입력으로 받는 heredoc · here-string 은 그 단위나 같은 파이프의 그 뒤 명령,
    또는 묶음 밖에서 이어지는 뒤 명령(downstream)이 표준입력을 명령으로 실행하면 명령으로 읽는다."""
    for p in pipes:
        for k, u in enumerate(p):
            later = downstream or any(shellish(v) for v in p[k + 1:])
            if u['group'] is not None:
                walk(u['group'], out, subs, later)
            else:
                out.append(u['words'])
            for doc in u['stdin']:
                if shellish(u) or later:
                    commands(doc['body'], out)
                elif not doc['quoted']:
                    expansions(doc['body'], subs)


def has_shell(toks):
    return any(shellish(u) for p in parse(toks)[0] for u in p)


def commands(text, out):
    """text 를 bash 처럼 읽어 실행될 단순 명령들을 out 에 더한다. 치환 안은 다 읽을 때까지 이어서 읽는다. 프로세스 치환
    안의 heredoc 은 늘 명령으로 본다 — 셸이 그 출력을 스크립트 파일로 읽을 수 있다. 출력을 셸에 보내는 프로세스 치환
    (`>(bash)`)이 있으면 모든 heredoc 을 명령으로 본다 — 그 셸이 어느 명령의 출력을 받는지 따라가지 않는다."""
    subs = []
    toks = lex(text, 0, False, subs)[0]
    feed = any(kind == '>' and has_shell(t) for t, kind in subs)
    walk(parse(toks)[0], out, subs, feed)
    k = 0
    while k < len(subs):
        t, kind = subs[k]
        walk(parse(t)[0], out, subs, feed or kind != '$')
        k += 1


out = []
try:
    commands(cmd, out)
except Unreadable as e:
    deny("리뷰어 가드가 명령을 bash 처럼 읽지 못했다(%s). 어디까지가 명령인지 몰라 콜드 리뷰어의 명령이라 막았다." % e)
except Exception as e:  # 훅이 예외로 끝나면 명령이 실행된다 — 읽다가 멈춘 것도 판정 못 한 것이다
    deny("리뷰어 가드가 명령을 읽다가 멈췄다(%s). 콜드 리뷰어의 명령이라 막았다." % type(e).__name__)


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


for words in out:
    reason = why(words)
    if reason:
        deny("콜드 리뷰어의 명령을 막았다 — %s: `%s`. 리뷰어는 게시하지 않고, 푸시하지 않고, 새 세션을 띄우지 않는다"
             "(cold-reviewer.md 「게시하지 마라. 호출자에게 돌려줘라」). 그것이 있어야 확인되는 것은 보고의 「확인 못 한 것」에 "
             "적어 부른 쪽이 사람에게 묻게 한다." % (reason, ' '.join(words)))
PY
