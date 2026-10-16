#!/usr/bin/env bash
# PreToolUse(Bash): GitHub 에 올리는 글(PR 본문 · PR 코멘트 · 이슈 본문 · 이슈 코멘트)의 접히지 않은 부분이 상한을
# 넘으면 그 게시 명령을 막는다. 필요: python3 · gh
#
# **왜.** 길이 규칙(「화면 한 장」)이 스킬 문서에 있었지만 막는 것이 없었고, 넣을 것을 늘리는 규칙만 쌓여 본문과
# 코멘트가 산문 문단과 펼친 명령 출력으로 길어졌다. 사람이 읽지 못하는 글은 사람이 보고 정하는 자리를 없앤다.
#
# **무엇을 보나.** `gh pr comment <N> --body-file <절대 경로>`(인용 훅과 같은 해석, `kit/round_comment_cmd.py`)와
# `gh pr create` · `gh issue create` · `gh issue comment` 의 `--body-file` · `-F` · `--body` · `-b`. 명령 안 어디에
# 있든(다른 명령과 이었어도), 하위 명령 앞이나 사이에 플래그가 있어도(`gh issue -R <레포> create`) 찾는다. `~` 는
# 홈으로, 상대 경로는 훅 입력의 cwd 로 푼다. 명령 안의 `cd` 는 따라가지 않는다. 따옴표 밖의 줄바꿈은 `;` 처럼 명령의
# 경계로 본다. 본문을 고쳐 쓰는 `gh pr edit` · `gh issue edit` 는 보지 않는다. 세면 상한이 생기기 전에 쓴 긴 본문은
# 한 줄만 고쳐도 막힌다.
#
# **어떻게 세나 · 상한은 얼마인가.** `kit/post_length.py` 머리에 있다. 게시할 글을 GitHub 의 markdown API 로 그려
# 세므로 게시마다 API 를 한 번(-R 이 없으면 레포 조회까지 두 번) 부른다.
#
# **판정 못 하면 막는다.** 본문 파일을 못 읽거나, 본문을 표준입력으로 주거나, 본문 없이 `gh pr create` 를 하거나
# (`--fill` 처럼 커밋으로 채운다. `--web` 은 빼고), 그리기가 실패하거나 gh 가 시간 안에 끝나지 않으면 막는다.
#
# **무엇을 못 막나.** 이 에이전트가 Bash 로 입력한 게시만 본다. 사람이 웹에서 쓴 글, `gh api` 로 올린 글, 명령 이름을
# 꾸민 게시(변수 · 별칭)는 보지 않는다. 인라인 본문(`--body`)의 셸 확장(`$(cat 파일)` · `$VAR`)은 확장하기 전 글자로
# 센다 — 막으려면 흔한 heredoc 꼴(`--body "$(cat <<'EOF' …)"`, 글이 명령 안에 있다)까지 막거나 셸을 흉내 내야 한다.
input=$(cat)
case "$input" in
  *gh*) ;;
  *) exit 0 ;;
esac
# 공유 파일(round_comment_cmd.py)을 읽어도 훅 디렉터리에 __pycache__ 를 남기지 않는다.
HOOK_INPUT="$input" PYTHONDONTWRITEBYTECODE=1 python3 "$(cd "$(dirname "$0")" && pwd)/kit/post_length.py"
exit 0
