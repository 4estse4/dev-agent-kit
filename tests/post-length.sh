#!/usr/bin/env bash
# 게시 글의 길이를 세는 훅(`claude-code/hooks/post_length.sh`)이 상한을 넘는 글을 막고 그 안의 글을 통과시키는가.
#
# **훅을 직접 부르는 쪽이 아니라 Claude Code 가 부르는 모양으로 부른다.** 표준입력에 도구 호출 JSON 을 넣어 훅의
# 명령 해석부터 거치게 한다. 세는 함수만 부르면 게시 명령을 못 알아보는 결함이 있어도 이 테스트가 통과한다.
#
# **네트워크를 안 쓴다.** 훅은 게시할 글을 GitHub 의 markdown API 로 그려 센다. 여기서는 PATH 앞에 둔 가짜 `gh` 가
# `-F text=@<파일>` 옆에 `<파일>.html` 이 있으면 그것을, 없으면 빈 줄이 아닌 줄마다 `<p>` 한 개를 그린 결과로 돌려준다.
# `repo view` 에는 `o/r` 을 내고, 받은 인자를 적어 둔다. `.html` 은 GitHub 이 실제로 낸 모양(`<details>` · `<summary>` ·
# `<pre>` · `<br>`)을 줄여 손으로 쓴 것이다. 실제 글을 그려 센 값은 이 훅을 더한 PR 의 본문 「검증」에 있다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$KIT/claude-code/hooks/post_length.sh"
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/w"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_GH_ARGS"
[ -n "${STUB_GH_FAIL:-}" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
[ -n "${STUB_GH_SLEEP:-}" ] && sleep "$STUB_GH_SLEEP"
if [ "${1:-} ${2:-}" = "repo view" ]; then echo o/r; exit 0; fi
exec python3 - "$@" <<'PY'
import html, os, sys
a = sys.argv[1:]
src = [x[len('text=@'):] for x in a if x.startswith('text=@')]
if a[:1] != ['api'] or 'markdown' not in a or not src:
    sys.stderr.write('stub gh: 모르는 호출: %s\n' % ' '.join(a))
    sys.exit(1)
if os.path.exists(src[0] + '.html'):
    sys.stdout.write(open(src[0] + '.html', encoding='utf-8').read())
else:
    for line in open(src[0], encoding='utf-8').read().split('\n'):
        if line.strip():
            print('<p dir="auto">%s</p>' % html.escape(line))
PY
EOF
chmod +x "$T/bin/gh"

fail=0
# 글자 c 를 n 개 이은 줄
rep() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }

# check <이름> <allow|deny> <명령> [사유에 있어야 할 글자] [작업 디렉터리]
check() {
  local name=$1 want=$2 cmd=$3 needle=${4:-} cwd=${5:-$T/w} input out got
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "$cmd" "$cwd")
  : > "$T/gh-args"
  out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" 2>&1)
  got=allow
  case "$out" in *'"permissionDecision": "deny"'*) got=deny ;; esac
  if [ "$got" != "$want" ]; then
    echo "  ✗ ${name}: ${want} 이어야 하는데 ${got} — ${out}"; fail=1; return
  fi
  if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then
    echo "  ✗ ${name}: 사유에 「${needle}」이 없다 — ${out}"; fail=1; return
  fi
  echo "  ✓ ${name}"
}

# 줄마다 <p> 하나가 되는 글. 줄 사이 줄바꿈은 공백 한 칸으로 센다
{ for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do rep 가 150; done; rep 나 37; } > "$T/w/at-limit.md"   # 총량 2000 · 가장 긴 줄 150
{ for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do rep 가 150; done; rep 나 38; } > "$T/w/over-total.md" # 총량 2001
rep 다 151 > "$T/w/over-line.md"
printf -- '- 짧은 항목\n  → 고칠 방향\n' > "$T/w/short.md"

# 접힌 출력: summary 만 센다. 펼친 출력: 총량에는 들고 한 줄 검사에는 안 든다
printf 'x\n' > "$T/w/folded.md"
{ echo '<p dir="auto">결과는 아래에 접었다</p>'; echo '<details>'; echo '<summary>게이트 통과 (rc=0)</summary>'
  echo '<pre class="notranslate"><code class="notranslate">'; for _ in $(seq 30); do rep 출 100; done; echo '</code></pre>'
  echo '</details>'; } > "$T/w/folded.md.html"
printf 'x\n' > "$T/w/open-fold.md"
sed 's/<details>/<details open="">/' "$T/w/folded.md.html" > "$T/w/open-fold.md.html"
printf 'x\n' > "$T/w/pre-long-line.md"
{ echo '<pre class="notranslate"><code class="notranslate">'; rep 출 300; echo '</code></pre>'; } > "$T/w/pre-long-line.md.html"
printf 'x\n' > "$T/w/br.md"
{ printf '<ul dir="auto">\n<li><strong>중간</strong> (콜드) %s<br>\n→ %s</li>\n</ul>\n' "$(rep 가 100)" "$(rep 나 100)"; } > "$T/w/br.md.html"
# 원문에서 줄을 바꿔 쓴 산문 문단. GitHub 은 문단 안의 줄바꿈을 <br> 와 줄바꿈으로 그린다
printf 'x\n' > "$T/w/br-prose.md"
{ printf '<p dir="auto">%s<br>\n%s</p>\n' "$(rep 가 100)" "$(rep 나 100)"; } > "$T/w/br-prose.md.html"
mkdir -p "$T/home"; rep 라 151 > "$T/home/over.md"
# 리뷰 전문 안에 접힌 블록이 또 있는 글. 바깥 블록의 끝은 짝을 센 </details> 다
printf 'x\n' > "$T/w/nested.md"
{ echo '<p dir="auto">짧은 머리</p>'; echo '<details>'; echo '<summary>콜드 리뷰 전문</summary>'
  echo '<p dir="auto">앞</p>'; echo '<details>'; echo '<summary>repro.sh</summary>'
  echo '<pre class="notranslate"><code class="notranslate">x</code></pre>'; echo '</details>'
  printf '<p dir="auto">%s</p>\n' "$(rep 가 200)"; echo '</details>'; } > "$T/w/nested.md.html"

echo "상한"
check "상한 그대로인 글은 통과" allow "gh pr comment 5 --body-file $T/w/at-limit.md"
check "총량이 한 자 넘으면 막는다" deny "gh pr comment 5 --body-file $T/w/over-total.md" "2001"
check "한 줄이 한 자 넘으면 막는다" deny "gh pr comment 5 --body-file $T/w/over-line.md" "151"
check "짧은 글은 통과" allow "gh pr comment 5 --body-file $T/w/short.md"

echo "접힌 부분"
check "접힌 출력은 summary 만 센다" allow "gh pr comment 5 --body-file $T/w/folded.md"
check "접힌 블록 안의 접힌 블록 뒤도 바깥 블록이 끝날 때까지 접혀 있다" allow "gh pr comment 5 --body-file $T/w/nested.md"
check "펼쳐 둔 <details open> 은 안을 센다" deny "gh pr comment 5 --body-file $T/w/open-fold.md" "총량"
check "펼친 코드 블록의 긴 줄은 한 줄 검사에 안 든다" allow "gh pr comment 5 --body-file $T/w/pre-long-line.md"
check "<br> 로 나뉜 →  줄은 따로 센다" allow "gh pr comment 5 --body-file $T/w/br.md"
check "<br> 로 줄을 바꿔 쓴 산문 문단은 한 줄로 센다" deny "gh pr comment 5 --body-file $T/w/br-prose.md" "201"

echo "게시 명령"
check "PR 본문(gh pr create)" deny "gh pr create --title t --body-file $T/w/over-line.md" "151"
check "PR 본문 고침(gh pr edit)은 보지 않는다" allow "gh pr edit 5 --body-file $T/w/over-line.md"
check "이슈 본문(gh issue create -F 상대 경로)" deny "gh issue create --title t -F over-line.md" "151"
check "이슈 본문 고침(gh issue edit)은 보지 않는다" allow "gh issue edit 7 --body-file=$T/w/over-line.md"
check "게시와 이은 고쳐 쓰는 명령도 보지 않는다" allow "gh pr edit 5 --body-file $T/w/over-line.md && gh issue edit 7 --body-file $T/w/over-line.md && gh issue comment 7 --body-file $T/w/short.md"
check "하위 명령 사이의 플래그(gh issue -R <레포> create)" deny "gh issue -R o/r create --title t --body-file $T/w/over-line.md" "151"
check "하위 명령 앞의 플래그(gh -R <레포> issue comment)" deny "gh -R o/r issue comment 7 --body-file $T/w/over-line.md" "151"
check "하위 명령 사이의 플래그(gh pr --repo=<레포> create)" deny "gh pr --repo=o/r create --title t --body-file $T/w/over-line.md" "151"
check "이슈 코멘트(gh issue comment --body 인라인)" deny "gh issue comment 7 --body $(rep 라 151)" "151"
check "다른 명령과 이은 게시" deny "cd $T/w && gh issue create --title t --body-file $T/w/over-line.md" "151"
check "이은 명령의 인자는 그 게시의 본문이 아니다" allow "gh issue create --title t --body-file $T/w/short.md && echo -F $T/w/over-line.md"
check "줄바꿈으로 이은 뒤 게시가 앞 게시의 본문을 덮지 않는다" deny "gh issue comment 7 --body-file $T/w/over-line.md
gh issue comment 8 --body-file $T/w/short.md" "151"
check "줄바꿈 뒤 명령의 --web 이 앞의 본문 없는 PR 열기를 덮지 않는다" deny "gh pr create --fill
gh pr view 5 --web" "본문"
check "따옴표 안의 줄바꿈은 본문에 남아 목록 항목마다 센다" allow "gh issue comment 7 --body \"- $(rep 가 60)
- $(rep 나 60)
- $(rep 다 60)\""
check "짧은 이슈 코멘트는 통과" allow "gh issue comment 7 --body-file $T/w/short.md"
check "본문을 표준입력으로 주면 막는다" deny "gh issue create --title t --body-file -" "표준입력"
check "없는 본문 파일은 막는다" deny "gh issue create --title t --body-file $T/w/none.md" "읽지 못"
check "본문 없는 PR 열기(--web)는 보지 않는다" allow "gh pr create --web"
check "도움말(gh pr create --help)은 보지 않는다" allow "gh pr create --help"
check "본문을 커밋에서 채우는 PR 열기(--fill)는 막는다" deny "gh pr create --fill" "본문"
check "--fill 에 본문 파일을 함께 주면 그 파일을 센다" allow "gh pr create --fill --body-file $T/w/short.md"
check "글자만 든 검색은 보지 않는다" allow "grep -rn 'gh issue create --body-file' $T/w"
check "목록 조회는 보지 않는다" allow "gh issue list --state open"

echo "그리기"
: > "$T/gh-args"
input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "gh pr comment 5 -R o2/r2 --body-file $T/w/short.md" "$T/w")
printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" >/dev/null 2>&1
if grep -q 'context=o2/r2' "$T/gh-args" && grep -q 'mode=gfm' "$T/gh-args"; then
  echo "  ✓ -R 의 레포를 context 로 그린다(gh pr comment)"
else
  echo "  ✗ -R 의 레포를 context 로 그리지 않았다(gh pr comment) — $(cat "$T/gh-args")"; fail=1
fi
input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "gh issue create -R o3/r3 --title t --body-file $T/w/short.md" "$T/w")
: > "$T/gh-args"
printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" >/dev/null 2>&1
if grep -q 'context=o3/r3' "$T/gh-args"; then
  echo "  ✓ -R 의 레포를 context 로 그린다(gh issue create)"
else
  echo "  ✗ -R 의 레포를 context 로 그리지 않았다(gh issue create) — $(cat "$T/gh-args")"; fail=1
fi
input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "gh pr comment 5 --body-file $T/w/short.md" "$T/w")
: > "$T/gh-args"
printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" >/dev/null 2>&1
if grep -q 'context=o/r' "$T/gh-args"; then
  echo "  ✓ -R 가 없으면 작업 디렉터리의 레포로 그린다"
else
  echo "  ✗ 작업 디렉터리의 레포로 그리지 않았다 — $(cat "$T/gh-args")"; fail=1
fi
input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' "gh pr comment 5 --body-file $T/w/short.md" "$T/w")
out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" STUB_GH_FAIL=1 bash "$HOOK" 2>&1)
case "$out" in
  *'"permissionDecision": "deny"'*'세지 못'*) echo "  ✓ 그리지 못하면 막는다" ;;
  *) echo "  ✗ 그리지 못했는데 막지 않았다 — $out"; fail=1 ;;
esac
# gh 가 훅의 시간 제한(30초) 안에 끝나지 않으면 판정하지 못한 것이다. 이 경우만 30초를 기다린다
out=$(printf '%s' "$input" | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" STUB_GH_SLEEP=40 bash "$HOOK" 2>&1)
case "$out" in
  *'"permissionDecision": "deny"'*'세지 못'*) echo "  ✓ gh 가 시간 안에 끝나지 않으면 막는다" ;;
  *) echo "  ✗ gh 가 시간 안에 끝나지 않았는데 막지 않았다 — $(printf '%s' "$out" | tail -1)"; fail=1 ;;
esac
input=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))' 'gh issue comment 7 --body-file ~/over.md' "$T/w")
out=$(printf '%s' "$input" | HOME="$T/home" PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" 2>&1)
case "$out" in
  *'"permissionDecision": "deny"'*'151'*) echo "  ✓ ~ 로 시작하는 본문 파일은 홈에서 찾아 센다" ;;
  *) echo "  ✗ ~ 로 시작하는 본문 파일을 홈에서 찾지 않았다 — $out"; fail=1 ;;
esac
out=$(printf '{"tool_name": "Write", "tool_input": {"file_path": "x"}}' | PATH="$T/bin:$PATH" STUB_GH_ARGS="$T/gh-args" bash "$HOOK" 2>&1)
if [ -z "$out" ]; then echo "  ✓ Bash 가 아닌 도구는 보지 않는다"; else echo "  ✗ Bash 가 아닌 도구에 출력이 있다 — $out"; fail=1; fi

echo "등록"
# 설치되는 settings 는 설치된 킷의 훅(.claude/hooks/)을, 이 레포의 settings 는 원본(claude-code/hooks/)을 가리킨다
for pair in "claude-code/settings.json:.claude/hooks/post_length.sh" ".claude/settings.json:claude-code/hooks/post_length.sh"; do
  s=${pair%%:*} want=${pair#*:}
  if python3 - "$KIT/$s" "$want" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))['hooks']
sys.exit(0 if any(m.get('matcher') == 'Bash' and any(sys.argv[2] in x.get('command', '') for x in m['hooks'])
                  for m in h.get('PreToolUse', [])) else 1)
PY
  then echo "  ✓ ${s} 가 ${want} 를 PreToolUse(Bash)에 등록한다"
  else echo "  ✗ ${s} 가 ${want} 를 PreToolUse(Bash)에 등록하지 않는다"; fail=1; fi
done

rm -rf "$T"
exit "$fail"
