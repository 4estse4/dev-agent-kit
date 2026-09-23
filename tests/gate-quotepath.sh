#!/usr/bin/env bash
# 설치되는 셸에서 경로 목록을 내는 git 명령은 전부 `-c core.quotePath=false` 를 단다.
#
# 이 테스트가 있는 이유: git 의 기본값은 비ASCII 경로를 octal 로 이스케이프해 따옴표째 낸다.
# 그 이름으로는 파일을 못 찾고 이름 검사에도 안 맞아, 한글 경로 아래의 .env 나 키 파일이
# 시크릿 스캔을 통과하고 한글 이름만 바뀐 모듈이 게이트의 검사 대상에서 빠졌다 — 조용히.
# 같은 결함이 이 레포에서 세 번 났다(pre-commit · gate.sh 의 한 줄 · 그 옆 네 자리). 매번
# 사람이나 리뷰가 잡았고, 한 줄만 고치고 같은 블록의 두 줄은 한 달 넘게 그대로였다.
# 새로 쓰는 자리를 잡는 것은 이 검사뿐이다.
#
# 보는 것: `.md` 가 아닌 설치되는 파일(common/ · claude-code/)과 install.sh 에서 주석이 아닌
# 줄 중, git 의 경로를 내는 부명령(diff · log · show · status · stash 에 --name-only ·
# --name-status · --porcelain · --short 가 붙은 것, 그리고 ls-files · ls-tree)이 든 줄. 그 줄에
# `core.quotePath=false` 가 없으면 실패한다. 부명령을 같이 보는 이유: `--short` 는
# rev-parse 와 symbolic-ref 에도 있고 그건 경로가 아니다(첫 판이 그 셋을 잡았다).
# 내용 diff(-p · -U0)는 경로 목록이 아니라 보지 않는다. 문서(.md)의 예시 명령도 보지
# 않는다 — 그건 사람이 읽는 출력이다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT" || exit 1

files=$(git ls-files common claude-code install.sh | grep -v -E '\.md$|settings\.json$')
[ -n "$files" ] || { echo "  ✗ 검사할 파일이 없다 — 경로가 바뀌었나"; exit 1; }

# git 과 부명령 사이에 -C <dir> · --no-optional-locks · -c k=v 같은 전역 옵션이 낄 수 있다.
PAT='git[[:space:]]([^|;&]*[[:space:]])?((diff|log|show|status|stash)[[:space:]][^|;&]*(--name-only|--name-status|--porcelain|--short)|ls-files|ls-tree)'
hits() { printf '%s\n' "$files" | xargs grep -n -E "$PAT" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#'; }

bad=$(hits | grep -v 'core\.quotePath=false')

if [ -n "$bad" ]; then
  echo "  ✗ 경로 목록을 내는 git 명령에 -c core.quotePath=false 가 없다:"
  printf '%s\n' "$bad" | sed 's/^/      /'
  exit 1
fi
n=$(hits | wc -l | tr -d ' ')
echo "  ✓ 경로 목록을 내는 git 명령 ${n}개가 전부 core.quotePath=false 를 단다"
