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
exit "$rc"
