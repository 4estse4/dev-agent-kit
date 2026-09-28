#!/usr/bin/env bash
# 창에서 사람이 고른 결정을 사람 계정으로 PR 에 코멘트로 올린다. 필요: gh · python3 · git
#
#     bash .claude/hooks/human_comment.sh <PR 번호> [-R <owner/repo>]
#
# **세션은 글을 쓰지 않는다.** 올리는 글은 창 기록 훅(`window_record.sh`)이 봇 디렉터리
# (`<git 공통 디렉터리>/ai-kit-bot/windows/<PR>.jsonl`)에 적어 둔 기록뿐이다 — 질문에 「이 결정은 사람 계정으로
# PR #N 에 그대로 올라간다」가 적힌 창에서 사람이 고른 보기로 만든 `- <머리말>: <보기>` 줄이다. 그래서 초안 ·
# sha256 · 권한 프롬프트가 없다. 창에서 고른 것이 게시 동의다. 세션은 봇 디렉터리를 읽지도 쓰지도 못한다.
#
# **무엇을 올리나.** 그 PR 의 아직 올리지 않은 기록을 모두, 창이 끝난 차례대로 한 코멘트에 모은다. 창에서 정한
# 뒤 올리기 전에 다른 결정 창이 또 끝나도 앞의 기록이 남지 않게 한다. 올린 기록의 수는 `<PR>.posted` 에 적는다.
# gh 가 실패하면 적지 않으므로 다음에 다시 올린다. 올리지 않은 기록 가운데 직접 쓴 말(`free`)이 있으면 하나도
# 올리지 않는다 — 그 말은 결정이 담긴 구간을 보기로 만든 창으로 다시 받는다(`open-pr` 3.5).
#
# 세션의 gh 는 봇 계정이므로, gh 를 봇 계정으로 보내는 환경 변수를 지우고 gh 를 불러 사람의 gh 로그인으로 올린다.
#
# 종료 코드: 올렸으면 0, 올릴 기록이 없거나 직접 쓴 말이 있거나 gh 가 실패하면 1, 인자가 틀리거나 봇 설정이
# 없으면 2.
set -uo pipefail
usage() {
  echo "사용: human_comment.sh <PR 번호> [-R <owner/repo>]" >&2
  exit 2
}
[ $# -eq 1 ] || [ $# -eq 3 ] || usage
pr=$1
repo=()
if [ $# -eq 3 ]; then
  [ "$2" = -R ] || usage
  repo=(-R "$3")
fi
[[ $pr =~ ^[0-9]+$ ]] || usage

top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$top" ] || [ ! -f "$top/.claude/bot.json" ]; then
  echo "봇 설정(.claude/bot.json)이 없다. 킷은 봇과 함께 쓴다 — 봇 설정이 없으면 사람 계정 코멘트를 올리지 않는다." >&2
  exit 2
fi
gitdir=$(git rev-parse --git-common-dir) || exit 2
case "$gitdir" in /*) ;; *) gitdir="$top/$gitdir" ;; esac
win="$gitdir/ai-kit-bot/windows"
body=$(mktemp) || exit 1
trap 'rm -f "$body"' EXIT
# 올릴 줄을 $body 에 쓰고, 올린 뒤 적을 기록 수를 출력한다. 올릴 수 없으면 까닭을 내고 1 로 끝난다.
n=$(python3 - "$win" "$pr" "$body" <<'PY'
import json, os, sys
win, pr, out = sys.argv[1:]
try:
    records = [json.loads(l) for l in open(os.path.join(win, pr + '.jsonl'), encoding='utf-8') if l.strip()]
except OSError:
    records = []
except ValueError:
    sys.stderr.write('창 기록을 읽지 못했다(모양이 틀렸다). 올리지 않는다.\n')
    sys.exit(1)
try:
    done = int(open(os.path.join(win, pr + '.posted')).read().strip() or 0)
except (OSError, ValueError):
    done = 0
todo = records[done:]
if not todo:
    sys.stderr.write('PR #%s 에 올릴 창 기록이 없다. 질문에 「이 결정은 사람 계정으로 PR #%s 에 그대로 올라간다」를 '
                     '적은 창으로 사람이 정한 뒤에 올린다.\n' % (pr, pr))
    sys.exit(1)
free = [h for r in todo for h in r.get('free') or []]
if free:
    sys.stderr.write('올리지 않은 기록에 사람이 보기 대신 직접 쓴 말(%s)이 있어 하나도 올리지 않는다. 결정이 담긴 이어진 '
                     '한 구간을 글자 그대로 보기로 만든 창을 다시 띄워 받는다(open-pr 3.5).\n' % ', '.join(free))
    sys.exit(1)
lines = [l for r in todo for l in r.get('lines') or []]
open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(len(records))
PY
) || exit 1
(
  unset GH_CONFIG_DIR GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_HOST
  gh pr comment "$pr" ${repo[@]+"${repo[@]}"} --body-file "$body"
) || exit 1
printf '%s\n' "$n" > "$win/$pr.posted"
