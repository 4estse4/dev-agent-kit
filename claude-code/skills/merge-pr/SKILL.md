---
name: merge-pr
description: 리뷰 반영과 CI 통과를 확인한 뒤 PR을 squash 머지하고 main으로 돌아온다. 머지는 이 스킬로만 한다.
argument-hint: "[PR 번호 | 비우면 현재 브랜치의 PR]"
---

## 꼭 지킬 것

**단계를 시작하기 전에 아래 「차례」에서 그 단계의 파일을 읽는다.** 이 파일에는 늘 지킬 것 · 차례 · 주입 · 1. PR 번호
확정만 있고, 그 밖의 단계마다 할 일과 그 까닭은 그 단계의 파일에 있다.

**컴팩션 뒤에는 진행 중인 단계의 파일을 다시 읽는다.** 컴팩션 뒤에는 이 파일의 앞부분만 다시 붙거나 아예 붙지
않고, 읽어 둔 보조 파일은 요약되어 절차가 빠질 수 있다.

**지시가 있어야 이 스킬을 실행한다.** 두 리뷰가 `Approve` 를 냈다는 것은 그 리뷰들의
의견이지 허락이 아니고, CI 가 초록인 것도 허락이 아니다. 허락은 사람이 한다.

지시 없이 이 스킬을 실행했으면 머지하지 말고 **`open-pr` 3.5 대로 사람에게 보고하고 멈춘다.** 예외는 하나다 —
다음 작업을 시작할 때 머지된 PR 을 정리하려고 부르는 것(3절 「다음 작업을 시작할 때 auto-merge 가 켜진 열린 PR 과
머지된 PR 을 본다」)은 지시 없이 부른다. 그때 2절은 `MERGED` 를 보고 4절과 5절만 한다.

레포에 봇 설정(`.claude/bot.json`)이 있으면 머지 승인은 사람 계정의 Approve 다. 세션은 결정 코멘트를 올리고
GitHub auto-merge 를 켠 뒤 Approve 를 요청하고, Approve 가 달리면 GitHub 이 머지한다(3절 「봇 설정이 있을
때」). 사람의 지시는 그 절차를 시작하라는 것이고, 머지를 허락하는 것은 Approve 다.

## 차례

- [checks.md](checks.md) — 2. 머지 전 안전 확인
- [merge.md](merge.md) — 3. 머지
- [cleanup.md](cleanup.md) — 4. base 복귀와 브랜치 삭제 · 5. 한 줄 보고

작업 트리:
!`git status --porcelain`

현재 브랜치의 PR:
!`gh pr view --json number -q .number 2>/dev/null || true`

$ARGUMENTS

---

## 1. PR 번호 확정
`$ARGUMENTS` 가 있으면 그것, 없으면 위 출력. 둘 다 없으면 중단:
`Error: PR 번호를 확정할 수 없습니다.`

