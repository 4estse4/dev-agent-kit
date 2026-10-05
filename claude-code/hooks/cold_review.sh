#!/usr/bin/env bash
# 콜드 리뷰 기록에서 그 head 의 보고 전문을 출력한다. 필요: python3 · git
#
#     bash .claude/hooks/cold_review.sh <리뷰한 head 40자> > <라운드 코멘트 조각 파일>
#
# **왜.** 라운드 코멘트에 싣는 콜드 리뷰 전문은 세션이 옮겨 적지 않고 이 출력을 그대로 넣는다. 기록은 기록 훅
# (`review_record.sh`)이 에이전트가 돌려준 글을 봇 디렉터리에 적은 것이고, 세션은 그 디렉터리를 읽지 못하므로
# 이 스크립트로 꺼낸다. 라운드 코멘트 게시 훅(`round_comment_cold.sh`)이 실린 전문을 같은 기록과 대조한다.
#
# 같은 head 에 기록이 여럿이면(리뷰를 다시 실행했으면) 마지막 것을 출력한다. 보고 끝에 줄바꿈 하나를 붙인다.
#
# 종료 코드: 0 출력함 · 1 그 head 의 기록이 없음 · 2 인자가 틀리거나 봇 설정이 없음
set -u
head="${1:-}"
if ! printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$'; then
  echo "쓰는 법: bash .claude/hooks/cold_review.sh <리뷰한 head 40자>" >&2
  exit 2
fi
top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$top" ] || [ ! -f "$top/.claude/bot.json" ]; then
  echo "봇 설정(.claude/bot.json)이 없다. 킷은 봇과 함께 쓴다 — 봇 설정이 없으면 콜드 리뷰를 기록하지 않는다." >&2
  exit 2
fi
gitdir=$(git rev-parse --path-format=absolute --git-common-dir) || exit 2
python3 - "$gitdir/kit-bot/reviews/$head.jsonl" "$head" <<'PY'
import json, sys
path, head = sys.argv[1:3]
last = None
try:
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r.get('report'), str):
                last = r['report']
except OSError:
    pass
if last is None:
    print("head %s 의 콜드 리뷰 기록이 없다. 콜드 리뷰 에이전트가 이 head 를 리뷰해 보고를 돌려줬는지 본다 — "
          "기록은 봇 설정이 있는 레포에서 cold-reviewer 에이전트의 보고만 남는다." % head, file=sys.stderr)
    sys.exit(1)
sys.stdout.write(last.rstrip('\n') + '\n')
PY
