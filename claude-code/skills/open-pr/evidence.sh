#!/usr/bin/env bash
# 명령을 실행해 그 명령 · 출력 · 종료 코드를 코드 블록째 파일에 덧붙인다. PR 본문과 머지
# 결정 코멘트의 증거를 손으로 옮기지 않게 한다.
#
#     bash <open-pr 스킬 디렉터리>/evidence.sh [--fold "<결과 한 줄>"] <조각 파일> <<'CMD'
#     <명령>
#     CMD
#
# **`--fold` 는 블록을 `<details>` 로 접는다.** `<summary>` 에 결과 한 줄과 `(rc=N)` 을 두고, 명령 · 출력 · `rc` 는
# 그 안에 둔다. GitHub 에 올리는 글은 접히지 않은 부분의 길이를 훅(`post_length.sh`)이 세고, 접힌 블록은
# `<summary>` 만 센다. 펼친 출력이 본문과 결정 코멘트를 읽히지 않게 길게 했다. `(rc=N)` 은 스크립트가 붙여,
# 세션이 쓴 결과 줄과 실제 종료 코드가 함께 보인다. 결과 줄의 `<` · `&` · `>` 는 글자로 바꾼다.
#
# **왜 스크립트인가.** 손으로 옮긴 출력이 잘렸다. 한 PR 본문에서 18줄 출력의 앞 넷이 세 번
# 빠졌고, 결정 코멘트에는 실행한 것과 다른 명령이 옮겨졌다(`git fetch -q` 를 실행하고 `-q` 없이
# 적었다). 「그대로 붙인다」는 규칙이 이미 있었는데도 출력이 잘리고 명령이 바뀌었다. 옮기는 단계를
# 없애야 막힌다.
#
# 명령은 표준입력으로 **한 번만** 받는다. 보이는 글자와 실행되는 글자가 같다. 따옴표 heredoc 으로
# 전달하면 셸이 명령을 건드리지 않는다. 둘째 줄부터는 `> ` 로 이어짐을 표시한다. 출력은 stderr
# 까지 담고 자르지 않는다. 펜스(```)는 명령과 출력에 든 가장 긴 백틱보다 길게 정해 블록이 안
# 깨진다. 덧붙인 블록은 표준출력에도 내서 부른 쪽도 본다.
#
# 종료 코드는 `rc=N` 으로 적고 이 스크립트도 그 코드로 끝난다. 실패가 본문에 남고 부른 쪽도
# 안다. 실패를 보이려고 실행한 명령(`grep` 이 아무것도 안 찾아 `rc=1`)이면 그 코드가 맞다.
set -u
usage="쓰는 법: bash evidence.sh [--fold \"<결과 한 줄>\"] <조각 파일> <<'CMD'  (명령)  CMD"
summary=''
fold=''
if [ "${1:-}" = --fold ]; then
  fold=1
  summary=${2:-}
  shift 2 2>/dev/null || shift $#
  case "$summary" in
    *$'\n'*) echo "evidence.sh: --fold 의 결과는 한 줄이다. $usage" >&2; exit 2 ;;
  esac
  if [ -z "${summary//[[:space:]]/}" ]; then
    echo "evidence.sh: --fold 의 결과 한 줄이 비었다. $usage" >&2
    exit 2
  fi
fi
if [ $# -ne 1 ]; then
  echo "$usage" >&2
  exit 2
fi
out=$1
cmd=$(cat)
if [ -z "${cmd//[[:space:]]/}" ]; then
  echo "evidence.sh: 명령이 비었다. 아무것도 덧붙이지 않았다." >&2
  exit 2
fi

# ask · deny 규칙 글자가 보이는 명령은 실행하지 않는다. 이 스크립트는 받은 글을 `bash -c` 로
# 실행하므로 권한 규칙이 그 안을 못 본다(공식 문서: a deny or ask rule "isn't a security boundary
# around the program"). 누가 이 스크립트를 allow 에 넣거나 「다시 묻지 않음」을 누르면 그 안의
# `gh pr merge` · `git push --force` 가 프롬프트 없이 실행된다. 증거는 읽기만 하는 명령이다.
# 규칙은 레포의 `.claude/settings.json` · `settings.local.json` 과 사람 · 관리 settings 파일에서 읽고(아래),
# 글자는 명령 어디에든 보이면 맞는다. `*` 는 아무 글자이고, 규칙의 공백 하나는 명령의 공백 하나 이상에 맞는다. 공식 문서대로 `*` 앞의 공백도 규칙의
# 일부라 `Bash(rm *)` 는 `rm ` 을 찾고 `--format` 의 `rm` 은 안 찾는다. 끝의 `:*` 는 ` *` 와 같다.
# 끝의 ` *` 가 유일한 와일드카드면 인자 없이 쓴 명령(`rm` · `rm;` · `rm>x` · `'rm'`)도 맞는다.
# 첫 낱말 앞은 낱말 경계라 `farm ` 도 맞지 않는다. 설정을 못 읽으면 막는다(관리 settings 는 아래). 이름을 꾸민 명령
# (변수 · 별칭)은 못 알아본다. 거부된 명령의 출력은 증거로 싣지 말고 무엇을 확인했는지 글로
# 적는다 — 직접 실행해 출력을 손으로 옮기면 이 스크립트가 없애려는 일이 다시 생긴다.
root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
# worktree 세션은 원래 체크아웃의 settings.local.json 을 쓴다(공식 문서 settings.md: "In a
# worktree, it uses the file at the main checkout's root."). 그 파일은 worktree 에 없으므로
# git 공통 디렉터리의 부모, 곧 원래 체크아웃의 것도 읽는다.
main=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && main=${main%/.git} || main=$root
# Claude Code 는 ask · deny 목록을 범위마다 합친다(공식 문서 settings.md: "Claude Code combines the lists
# instead of picking one"). 그래서 사람 settings 와 관리 settings 파일의 규칙도 대조한다. 사람 settings 는
# CLAUDE_CONFIG_DIR 이 있으면 그 디렉터리의, 없으면 ~/.claude 의 settings.json 이다. 관리 settings 파일은 시스템
# 디렉터리의 managed-settings.json 과 managed-settings.d/*.json 이다(공식 문서 managed-settings.md). 관리 출처가
# 여럿이면 Claude Code 는 기본값(first-wins)에서 하나만 쓰지만 파일은 늘 대조한다 — 쓰이지 않는 규칙까지 보면 더
# 막을 뿐이다. 운영체제가 읽기를 막은 관리 settings 는 Claude Code 처럼 건너뛴다(같은 문서: "every session starts
# without that source's policies"). 빈 관리 settings 파일은 Claude Code 처럼 {} 로 본다(같은 문서: "An empty managed
# settings file counts as {}"). 형식이 틀린 관리 settings 는 막는다 — 그때 Claude Code 는 시작을 거부한다. 서버 관리 settings(캐시 ~/.claude/remote-settings.json) · macOS 구성 프로필 ·
# 실행할 때 준 --settings · --disallowedTools 의 규칙은 이 스크립트가 대조하지 않는다.
user=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
case "$(uname)" in
  Darwin) sys="/Library/Application Support/ClaudeCode" ;;
  *) sys=/etc/claude-code ;;
esac
# 파이썬은 명령 치환 밖의 heredoc 으로 담는다. 명령 치환 안의 heredoc 이면 macOS 기본 bash(3.2)가
# 짝 없는 따옴표 · 백틱을 세어 스크립트 전체를 구문 오류로 실패하게 한다. CI 의 bash 5 는 그것을 못 본다.
IFS= read -r -d '' prog <<'PY' || true
import json, os, re, sys
cmd = os.environ['EVIDENCE_CMD']
managed = False
for path in sys.argv[1:]:
    if path == '--managed':            # 뒤의 경로는 관리 settings 다
        managed = True
        continue
    if not os.path.exists(path):
        continue
    try:
        text = open(path, encoding='utf-8').read()
        data = {} if managed and not text.strip() else json.loads(text)
        perms = data.get('permissions') or {}
        rules = [(k, r) for k in ('ask', 'deny') for r in perms.get(k) or []]
    except (OSError, ValueError, AttributeError, TypeError) as e:
        if managed and isinstance(e, PermissionError):
            continue
        print('%s 를 읽지 못했다(%s)' % (path, e))
        sys.exit(1)
    for kind, rule in rules:
        m = re.fullmatch(r'Bash\((.*)\)', str(rule).strip(), re.S)
        if not m:
            continue
        pat = m.group(1).strip()
        if pat.endswith(':*'):
            pat = pat[:-2] + ' *'
        # 끝이 공백 뒤 `*` 이고 그것이 유일한 와일드카드면 인자 없이 쓴 명령도 맞는다("also matches the
        # bare command" · "only when the trailing `*` is the rule's only wildcard"). 그 공백 자리는
        # 공백 · 명령 끝 · 구분자 · 리다이렉트 · 따옴표 · 백틱 가운데 하나다.
        stripped = re.sub(r'\s+\*$', '', pat)
        bare = stripped != pat and '*' not in stripped
        if bare:
            pat = stripped
        parts = pat.split('*')
        pieces = [r'\s+'.join(map(re.escape, re.split(r'\s+', p))) for p in parts if p]
        if not pieces:
            pieces = ['']
        rx = '.*'.join(pieces)
        if parts[0]:
            rx = r'(?<![\w-])' + rx
        if bare:
            rx += r'(?![^\s;&|()<>`\'"])'
        if re.search(rx, cmd, re.S):
            print('%s 의 %s 규칙 %s 의 글자가 보인다' % (os.path.basename(path), kind, rule))
            sys.exit(1)
PY
why=$(EVIDENCE_CMD="$cmd" python3 -c "$prog" "$root/.claude/settings.json" \
      "$root/.claude/settings.local.json" "$main/.claude/settings.local.json" "$user" \
      --managed "$sys/managed-settings.json" "$sys"/managed-settings.d/*.json 2>&1) || {
  echo "evidence.sh: 이 명령을 증거로 실행하지 않는다. $why" >&2
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
  if [ -n "$fold" ]; then
    printf '<details>\n<summary>%s (rc=%s)</summary>\n\n' \
      "$(printf '%s' "$summary" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')" "$rc"
  fi
  printf '%s\n' "$fence"
  mark='$'
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s %s\n' "$mark" "$line"
    mark='>'
  done <<<"$cmd"
  [ -n "$res" ] && printf '%s\n' "$res"
  printf 'rc=%s\n%s\n' "$rc" "$fence"
  [ -n "$fold" ] && printf '\n</details>\n'
} | tee -a "$out"
# 덧붙이기가 실패하면(없는 디렉터리 · 잘못 적은 경로) 표준출력에는 블록이 나와도 조각에는
# 없다. 명령의 rc 로 끝나면 성공처럼 보여 그 조각이 본문에서 알림 없이 빠진다.
if [ "${PIPESTATUS[1]}" != 0 ]; then
  echo "evidence.sh: $out 에 덧붙이지 못했다." >&2
  exit 3
fi
exit "$rc"
