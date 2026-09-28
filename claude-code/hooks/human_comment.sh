#!/usr/bin/env bash
# 사람이 권한 프롬프트에서 읽고 허락한 글을 사람 계정으로 PR 에 코멘트로 올린다. 필요: gh · shasum
#
#     bash .claude/hooks/human_comment.sh <PR 번호> <본문 파일의 절대 경로> <본문의 sha256> [-R <owner/repo>]
#
# 봇 설정(`.claude/bot.json`)이 있는 레포에서 사람의 결정을 사람 계정 코멘트로 남기는 두 길 가운데
# 하나다. 다른 길은 사람이 PR 웹에서 직접 쓰는 것이다. 세션의 gh 는 봇 계정이므로, 이 스크립트는 gh 를
# 봇 계정으로 보내는 환경 변수를 지우고 gh 를 불러 사람의 gh 로그인으로 올린다.
#
# **올리기 전의 확인.** 세션은 이 명령 바로 전에 응답에 올릴 글의 최종본 전문을 출력한다. `bot_guard.sh`
# 가 이 명령에 권한 프롬프트(`ask`)를 내고, 사람이 응답의 글을 읽고 허락해야 이 스크립트가 실행된다. 훅은
# 사유에도 글 전문을 넣지만 폰 화면에는 보이지 않았다. 명령의 sha256 은 허락한 글과 올리는 글이 같은지
# 확인한다 — 허락과 실행 사이에 파일이 바뀌면 올리지 않는다.
#
# 종료 코드: 올렸으면 gh 의 종료 코드, sha256 이 다르면 1, 인자가 틀리거나 봇 설정이 없으면 2.
set -uo pipefail
usage() {
  echo "사용: human_comment.sh <PR 번호> <본문 파일의 절대 경로> <본문의 sha256> [-R <owner/repo>]" >&2
  exit 2
}
[ $# -eq 3 ] || [ $# -eq 5 ] || usage
pr=$1 file=$2 sum=$3
repo=()
if [ $# -eq 5 ]; then
  [ "$4" = -R ] || usage
  repo=(-R "$5")
fi
[[ $pr =~ ^[0-9]+$ ]] || usage
case $file in /*) ;; *) usage ;; esac

top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$top" ] || [ ! -f "$top/.claude/bot.json" ]; then
  echo "봇 설정(.claude/bot.json)이 없다. 세션의 gh 가 사람 계정이므로 gh pr comment 로 올린다." >&2
  exit 2
fi
got=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
if [ -z "$got" ] || [ "$got" != "$sum" ]; then
  echo "본문 파일의 sha256 이 명령에 적은 값과 다르다. 권한 프롬프트에 보인 글과 다른 글이라 올리지 않는다." >&2
  exit 1
fi
unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_HOST
exec gh pr comment "$pr" ${repo[@]+"${repo[@]}"} --body-file "$file"
