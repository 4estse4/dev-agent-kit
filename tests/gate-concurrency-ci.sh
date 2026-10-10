#!/usr/bin/env bash
# CI 의 concurrency 가 main 에 잇달아 온 푸시의 실행을 서로 취소하지 않는가.
#
# 이 테스트가 있는 이유: gates.yml 의 concurrency 가 `group: <워크플로>-<ref>` · `cancel-in-progress: true` 라, main 에
# 푸시 둘이 잇달아 오면 앞 실행이 취소됐다. push 의 시크릿 스캔은 그 푸시가 들여온 커밋(before..after)만 보므로 앞 푸시가
# 들여온 커밋은 어느 실행도 시크릿 스캔으로 보지 않았다(이슈 #176). PR 은 base..head 를 보므로 앞 실행이 취소돼도 빠지는
# 커밋이 없고, 같은 PR 의 앞 실행은 지금처럼 취소한다.
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 의 워크플로 concurrency 를 읽는다. `${{ … }}` 는 GitHub 식의 부분집합(문맥 값 ·
# 문자열 · == · != · && · || · ! · 괄호 · format)으로 경우마다 계산한다. 모르는 문맥이나 함수가 나오면 값을 짐작하지 않고
# 실패한다. 보는 것:
#   · 다른 커밋을 main 에 잇달아 푸시한 두 실행은 그룹이 다르다
#   · 같은 커밋을 main 과 master 에 푸시한 두 실행도 그룹이 다르다 — 브랜치가 다르면 서로 취소하지 않는다
#   · 같은 PR 의 두 실행(머지 커밋이 다르다)은 그룹이 같고, 그때 cancel-in-progress 가 참이다 — 앞 실행을 취소한다
#   · 다른 PR 의 실행은 그룹이 다르다
#   · 잡마다 둔 concurrency 가 없다 — 있으면 잡 단위로 다시 취소될 수 있는데 이 테스트가 그것을 계산하지 않는다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/installed"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; rm -rf "$T"; exit 1; }
Y="$R/.github/workflows/gates.yml"
[ -f "$Y" ] || { echo "  ✗ $Y 가 없다 — 설치 경로가 바뀌었나"; rm -rf "$T"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  ✗ python3 의 yaml 모듈이 없다 — gates.yml 을 읽을 수 없다"; rm -rf "$T"; exit 1; }

python3 - "$Y" <<'PY' || fail=1
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
bad = 0
def ok(m): print(f"  ✓ {m}")
def ng(m):
    global bad
    print(f"  ✗ {m}"); bad = 1

conc = doc.get('concurrency')
if not isinstance(conc, dict) or 'group' not in conc:
    print("  ✗ 워크플로의 concurrency 에 group 이 없다 — 이 테스트가 볼 것이 없다"); sys.exit(1)
for name, job in doc['jobs'].items():
    if 'concurrency' in job:
        ng(f"{name} 잡이 concurrency 를 둔다 — 잡 단위 취소는 이 테스트가 계산하지 않는다")

class Unknown(Exception): pass

def tokens(s):
    i, out = 0, []
    while i < len(s):
        c = s[i]
        if c.isspace(): i += 1; continue
        if c == "'":
            j, buf = i + 1, ''
            while True:
                if j >= len(s): raise Unknown(f"닫히지 않은 문자열 — {s}")
                if s[j] == "'":
                    if s[j + 1:j + 2] == "'": buf += "'"; j += 2; continue
                    break
                buf += s[j]; j += 1
            out.append(('str', buf)); i = j + 1; continue
        two = s[i:i + 2]
        if two in ('==', '!=', '&&', '||'): out.append(('op', two)); i += 2; continue
        if c in '!(),': out.append(('op', c)); i += 1; continue
        m = re.match(r'[A-Za-z_][A-Za-z0-9_.-]*', s[i:])
        if m: out.append(('id', m.group(0))); i += len(m.group(0)); continue
        raise Unknown(f"읽지 못한 글자 — {s[i:]}")
    return out

def truthy(v): return v not in (False, None, 0, '')
def text(v):
    if v is True: return 'true'
    if v is False: return 'false'
    if v is None: return ''
    return str(v)

def evaluate(expr, ctx):
    toks, pos = tokens(expr), 0
    def peek(): return toks[pos] if pos < len(toks) else (None, None)
    def take(kind=None, val=None):
        nonlocal pos
        t = peek()
        if (kind and t[0] != kind) or (val and t[1] != val): raise Unknown(f"식의 꼴을 읽지 못했다 — {expr}")
        pos += 1; return t
    def primary():
        k, v = peek()
        if (k, v) == ('op', '('):
            take(); r = orr(); take('op', ')'); return r
        if (k, v) == ('op', '!'):
            take(); return not truthy(primary())
        if k == 'str': take(); return v
        if k == 'id':
            take()
            if v in ('true', 'false'): return v == 'true'
            if v == 'null': return None
            if peek() == ('op', '('):
                take(); args = []
                if peek() != ('op', ')'):
                    args.append(orr())
                    while peek() == ('op', ','): take(); args.append(orr())
                take('op', ')')
                if v == 'format':
                    return re.sub(r'\{(\d+)\}', lambda m: text(args[1 + int(m.group(1))]), args[0])
                raise Unknown(f"모르는 함수다 — {v}. 값을 짐작하지 않는다")
            if v not in ctx: raise Unknown(f"모르는 문맥이다 — {v}. 값을 짐작하지 않는다")
            return ctx[v]
        raise Unknown(f"식의 꼴을 읽지 못했다 — {expr}")
    def eq():
        l = primary()
        while peek()[1] in ('==', '!='):
            op = take()[1]; r = primary()
            same = l.lower() == r.lower() if isinstance(l, str) and isinstance(r, str) else l == r
            l = same if op == '==' else not same
        return l
    def andd():
        l = eq()
        while peek() == ('op', '&&'):
            take(); r = eq(); l = r if truthy(l) else l
        return l
    def orr():
        l = andd()
        while peek() == ('op', '||'):
            take(); r = andd(); l = l if truthy(l) else r
        return l
    v = orr()
    if pos != len(toks): raise Unknown(f"식 끝에 읽지 못한 것이 있다 — {expr}")
    return v

def render(s, ctx):
    s = str(s)
    if '${{' not in s: return s
    return re.sub(r'\$\{\{(.*?)\}\}', lambda m: text(evaluate(m.group(1), ctx)), s)

def value(v, ctx):  # 값 전체가 식 하나면 그 식의 값(참 · 거짓 그대로), 아니면 글자로 이은 값
    if isinstance(v, str):
        m = re.fullmatch(r'\s*\$\{\{(.*?)\}\}\s*', v)
        return evaluate(m.group(1), ctx) if m else render(v, ctx)
    return v

name = doc.get('name', '')
def push(ref, sha):
    return {'github.workflow': name, 'github.event_name': 'push', 'github.ref': ref, 'github.sha': sha}
def pr(n, merge_sha):
    return {'github.workflow': name, 'github.event_name': 'pull_request',
            'github.ref': f'refs/pull/{n}/merge', 'github.sha': merge_sha}
A, B, C = 'a' * 40, 'b' * 40, 'c' * 40
try:
    g = lambda ctx: render(conc['group'], ctx)
    cancel = lambda ctx: truthy(value(conc.get('cancel-in-progress', False), ctx))
    p1, p2 = g(push('refs/heads/main', A)), g(push('refs/heads/main', B))
    (ok if p1 != p2 else ng)(f"다른 커밋을 main 에 잇달아 푸시한 두 실행은 그룹이 다르다({p1} · {p2})")
    m1, m2 = g(push('refs/heads/main', A)), g(push('refs/heads/master', A))
    (ok if m1 != m2 else ng)(f"같은 커밋을 main 과 master 에 푸시한 두 실행은 그룹이 다르다({m1} · {m2})")
    q1, q2 = g(pr(5, B)), g(pr(5, C))
    (ok if q1 == q2 and cancel(pr(5, C)) else ng)(
        f"같은 PR 의 두 실행은 그룹이 같고 앞 실행을 취소한다({q1} · {q2}, cancel-in-progress={text(cancel(pr(5, C))).lower()})")
    r1, r2 = g(pr(5, B)), g(pr(6, B))
    (ok if r1 != r2 else ng)(f"다른 PR 의 실행은 그룹이 다르다({r1} · {r2})")
except Unknown as e:
    print(f"  ✗ {e}"); sys.exit(1)
sys.exit(bad)
PY

rm -rf "$T"
exit $fail
