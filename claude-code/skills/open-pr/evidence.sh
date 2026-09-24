#!/usr/bin/env bash
# 명령을 돌려 그 명령 · 출력 · 종료 코드를 코드 블록째 파일에 덧붙인다. PR 본문과 머지
# 결정 코멘트의 증거를 손으로 옮기지 않게 한다.
#
#     bash .claude/skills/open-pr/evidence.sh <조각 파일> <<'CMD'
#     <명령>
#     CMD
#
# **왜 스크립트인가.** 손으로 옮긴 출력이 잘렸다. 한 PR 본문에서 18줄 출력의 앞 넷이 세 번
# 빠졌고, 결정 코멘트에는 돌린 것과 다른 명령이 옮겨졌다(`git fetch -q` 를 돌리고 `-q` 없이
# 적었다). 「그대로 붙인다」는 규칙이 이미 있었고 그래도 났다. 옮기는 단계를 없애야 막힌다.
#
# 명령은 표준입력으로 **한 번만** 받는다. 보이는 글자와 도는 글자가 같다. 따옴표 heredoc 으로
# 넘기면 셸이 명령을 건드리지 않는다. 둘째 줄부터는 `> ` 로 이어짐을 표시한다. 출력은 stderr
# 까지 담고 자르지 않는다. 울타리는 명령과 출력에 든 가장 긴 백틱보다 길게 잡아 블록이 안
# 깨진다. 덧붙인 블록은 표준출력에도 내 부른 쪽이 본다.
#
# 종료 코드는 `rc=N` 으로 적고 이 스크립트도 그 코드로 끝난다. 실패가 본문에 남고 부른 쪽도
# 안다. 실패를 보이려고 돌린 명령(`grep` 이 아무것도 안 찾아 `rc=1`)이면 그 코드가 맞다.
set -u
if [ $# -ne 1 ]; then
  echo "쓰는 법: bash evidence.sh <조각 파일> <<'CMD'  (명령)  CMD" >&2
  exit 2
fi
out=$1
cmd=$(cat)
if [ -z "${cmd//[[:space:]]/}" ]; then
  echo "evidence.sh: 명령이 비었다. 아무것도 덧붙이지 않았다." >&2
  exit 2
fi

# ask · deny 규칙 글자가 보이는 명령은 돌리지 않는다. 이 스크립트는 받은 글을 `bash -c` 로
# 돌리므로 권한 규칙이 그 안을 못 본다(공식 문서: a deny or ask rule "isn't a security boundary
# around the program"). 누가 이 스크립트를 allow 에 넣거나 「다시 묻지 않음」을 누르면 그 안의
# `gh pr merge` · `git push --force` 가 프롬프트 없이 돈다. 증거는 읽기만 하는 명령이다.
# 규칙은 레포의 `.claude/settings.json` · `settings.local.json` 에서 읽고, 글자는 명령 어디에든
# 보이면 걸린다. `*` 는 아무 글자, 공백은 공백 여럿이다. 공식 문서대로 `*` 앞의 공백도 규칙의
# 일부라 `Bash(rm *)` 는 `rm ` 을 찾고 `--format` 의 `rm` 은 안 찾는다. 끝의 `:*` 는 ` *` 와 같다.
# 첫 낱말 앞은 낱말 경계라 `farm ` 도 안 걸린다. 설정을 못 읽으면 막는다. 이름을 꾸민 명령
# (변수 · 별칭)은 못 알아본다. 거부된 명령의 출력은 증거로 싣지 말고 무엇을 확인했는지 글로
# 적는다 — 직접 돌려 손으로 옮기면 이 스크립트가 없애려는 경로로 돌아간다.
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
why=$(EVIDENCE_CMD="$cmd" python3 - "$root/.claude/settings.json" "$root/.claude/settings.local.json" 2>&1 <<'PY'
import json, os, re, sys
cmd = os.environ['EVIDENCE_CMD']
for path in sys.argv[1:]:
    if not os.path.exists(path):
        continue
    try:
        perms = json.load(open(path, encoding='utf-8')).get('permissions') or {}
        rules = [(k, r) for k in ('ask', 'deny') for r in perms.get(k) or []]
    except (OSError, ValueError, AttributeError, TypeError) as e:
        print('%s 를 읽지 못했다(%s)' % (path, e))
        sys.exit(1)
    for kind, rule in rules:
        m = re.fullmatch(r'Bash\((.*)\)', str(rule).strip(), re.S)
        if not m:
            continue
        pat = m.group(1).strip()
        if pat.endswith(':*'):
            pat = pat[:-2] + ' *'
        parts = pat.split('*')
        pieces = [r'\s+'.join(map(re.escape, re.split(r'\s+', p))) for p in parts if p]
        if not pieces:
            pieces = ['']
        rx = '.*'.join(pieces)
        if parts[0]:
            rx = r'(?<![\w-])' + rx
        if re.search(rx, cmd, re.S):
            print('%s 의 %s 규칙 %s 의 글자가 보인다' % (os.path.basename(path), kind, rule))
            sys.exit(1)
PY
) || {
  echo "evidence.sh: 이 명령을 증거로 돌리지 않는다. $why" >&2
  echo "  그 출력은 증거로 싣지 말고 무엇을 확인했는지 글로 적는다. 손으로 옮기지 않는다." >&2
  exit 2
}

res=$(bash -c "$cmd" 2>&1 </dev/null)
rc=$?

fence='```'
while printf '%s\n%s\n' "$cmd" "$res" | grep -qF -- "$fence"; do
  fence="$fence\`"
done

{
  printf '%s\n' "$fence"
  mark='$'
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s %s\n' "$mark" "$line"
    mark='>'
  done <<<"$cmd"
  [ -n "$res" ] && printf '%s\n' "$res"
  printf 'rc=%s\n%s\n' "$rc" "$fence"
} | tee -a "$out"
# 덧붙이기가 실패하면(없는 디렉터리 · 잘못 적은 경로) 표준출력에는 블록이 나와도 조각에는
# 없다. 명령의 rc 로 끝나면 성공처럼 보여 그 조각이 본문에서 조용히 빠진다.
if [ "${PIPESTATUS[1]}" != 0 ]; then
  echo "evidence.sh: $out 에 덧붙이지 못했다." >&2
  exit 3
fi
exit "$rc"
