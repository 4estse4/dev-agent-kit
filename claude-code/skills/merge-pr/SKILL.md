---
name: merge-pr
description: 리뷰 반영과 CI 통과를 확인한 뒤 PR을 squash 머지하고 main으로 돌아온다. 머지는 이 스킬로만 한다.
argument-hint: "[PR 번호 | 비우면 현재 브랜치의 PR]"
---

작업 트리:
!`git status --porcelain`

현재 브랜치의 PR:
!`gh pr view --json number -q .number 2>/dev/null`

$ARGUMENTS

---

## 1. PR 번호 확정
`$ARGUMENTS` 가 있으면 그것, 없으면 위 출력. 둘 다 없으면 중단:
`Error: PR 번호를 확정할 수 없습니다.`

## 2. 머지 전 안전 확인 — 하나라도 실패하면 즉시 중단

- `gh pr view <N> --json state -q .state` → `OPEN` 이 아니면 중단.
- `gh pr checks <N>` → `fail` 또는 `pending` 이 하나라도 있으면 중단하고 해당 체크를 나열한다.
- 위 `git status --porcelain` 이 비어 있지 않으면 중단.
- **리뷰 반영 확인**: `review-diff` 가 남긴 `Request changes` 가 해소되지 않았으면 중단.

> 이 확인은 편의이지 강제가 아니다. 진짜 강제는 GitHub 브랜치 보호다
> (킷의 `install.sh <경로> --protect`). 브랜치 보호가 없는 레포라면 그 사실을 먼저 알린다.

## 3. 머지
`git log main..HEAD --format='%s'` 로 커밋 제목을 보고 사소한 것(리뷰수정·fixup·포맷)을 뺀
목록을 만든 뒤:

`gh pr merge <N> --squash --delete-branch --body "<추린 목록, 없으면 빈 문자열>"`

`git branch -d` 를 따로 실행하지 않는다 — `--delete-branch` 가 처리한다.

## 4. main 복귀
`git checkout main` → `git pull --ff-only`.
fast-forward 실패 시 중단: `Error: main 을 fast-forward 할 수 없습니다.`

## 5. 한 줄 보고
`Merged PR #<N>. main at <short SHA>.`

이후 새 작업을 시작하지 않는다.
