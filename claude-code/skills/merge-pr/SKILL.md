---
name: merge-pr
description: 리뷰 반영과 CI 통과를 확인한 뒤 PR을 squash 머지하고 main으로 돌아온다. 머지는 이 스킬로만 한다.
argument-hint: "[PR 번호 | 비우면 현재 브랜치의 PR]"
---

## 차례

- [checks.md](checks.md) — 2. 머지 전 안전 확인
- [merge.md](merge.md) — 3. 머지
- [cleanup.md](cleanup.md) — 4. base 복귀와 브랜치 삭제 · 5. 한 줄 보고

작업 트리:
!`git status --porcelain`

현재 브랜치의 PR:
!`gh pr view --json number -q .number 2>/dev/null`

$ARGUMENTS

---

## 1. PR 번호 확정
`$ARGUMENTS` 가 있으면 그것, 없으면 위 출력. 둘 다 없으면 중단:
`Error: PR 번호를 확정할 수 없습니다.`

