#!/usr/bin/env bash
# PR 본문 · 라운드 코멘트 · 결정 코멘트의 조각을 둘 새 디렉터리를 만들고 그 절대 경로를 출력한다.
#
#     bash <open-pr 스킬 디렉터리>/drafts.sh <이름>
#
# 자리는 레포 루트(worktree 면 그 worktree 의 루트)의 `.kit/drafts/<이름>.XXXXXX` 다. 처음 부를 때
# `.kit/drafts/.gitignore` 를 `*` 한 줄로 만든다 — 그 파일까지 git 이 무시해서 커밋할 것이 없고, 어느 clone ·
# worktree 에서도 처음 부를 때 생긴다.
#
# **왜 git 디렉터리가 아닌가.** 조각을 레포의 git 디렉터리 안에 두었더니 그 자리가 Claude Code 의 보호 경로라,
# 조각을 쓰고 고칠 때마다 `default` · `acceptEdits` 에서 권한 프롬프트가 표시됐고 `allow` 로 미리 풀 수도 없었다
# (공식 문서 permission-modes.md 의 「Protected paths」). `.kit` 은 그 목록에 없어 `acceptEdits` · `auto` 에서
# 쓰기를 묻지 않는다.
#
# 이 자리를 다른 도구가 보지 않게 한 곳이 셋이다. 하나를 바꾸면 나머지도 맞춘다.
#   · 설치기(`install.sh`)는 `.kit/` 를 비울 때와 킷과 무관한 `.kit/` 를 판정할 때 `.kit/drafts` 를 뺀다
#   · 포맷 훅(`post_edit.sh`)은 이 아래 파일을 포맷하지 않는다 — 포맷되면 사람이 본 글과 올라가는 글이 달라진다
#   · 킷의 `.prettierignore` 템플릿이 `.kit/` 를 뺀다 — prettier 는 하위 디렉터리의 `.gitignore` 를 따르지 않는다
set -eu
[ $# -eq 1 ] && [ -n "$1" ] || { echo "쓰는 법: bash drafts.sh <이름>   예: bash drafts.sh pr-body" >&2; exit 2; }
root=$(git rev-parse --show-toplevel)
mkdir -p "$root/.kit/drafts"
[ -f "$root/.kit/drafts/.gitignore" ] || printf '*\n' > "$root/.kit/drafts/.gitignore"
mktemp -d "$root/.kit/drafts/$1.XXXXXX"
