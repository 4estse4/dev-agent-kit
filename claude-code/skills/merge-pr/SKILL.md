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

## 2. 머지 전 안전 확인

### 전제 — 사람이 머지를 지시했을 때만 진행한다

**지시가 있어야 이 스킬이 돈다.** 리뷰 두 층이 `Approve` 를 냈다는 것은 그 층들의
의견이지 허락이 아니고, CI 가 초록인 것도 허락이 아니다. 허락은 사람이 한다.

지시 없이 여기까지 왔으면 머지하지 말고 **`open-pr` 3단계의 다섯 번째 항목(멈추고 보고)대로 보고하고 멈춘다.**

### 그다음 — 하나라도 실패하면 즉시 중단

- `gh pr view <N> --json state -q .state` → `OPEN` 이 아니면 중단.
- `gh pr checks <N>` → `fail` 또는 `pending` 이 하나라도 있으면 중단하고 해당 체크를 나열한다.
- 위 `git status --porcelain` 이 비어 있지 않으면 중단.
- **리뷰 반영 확인.** `open-pr` 이 올린 **마지막 라운드 코멘트**를 읽는다:

      gh pr view <N> --json comments \
        --jq '[.comments[] | select(.body|startswith("## 리뷰 "))] | last | .body'

  그 코멘트 **맨 위의** `리뷰한 head:` 를 지금 서버 head 와 비교한다
  (`gh pr view <N> --json headRefOid -q .headRefOid`). 접힌 전문 안에도 같은 줄이
  있으므로 맨 위 것을 쓴다.

  **다르면** 마지막 라운드 뒤에 커밋이 더 쌓인 것이고 그 커밋들은 아무도 안 봤다.
  중단하고 **어느 커밋인지 나열해** 사람에게 말한다(`git log <그 head>..HEAD --oneline`).
  사람이 그것을 알고도 머지하라고 하면 진행하되, **3절의 결정 코멘트에 그 커밋 목록과
  "리뷰를 거치지 않았다" 를 적는다.** 이것은 정상 경로다 — `open-pr` 이 사람에게
  제시하는 답에 "고치고 추가 라운드 없이 머지" 가 들어 있고, 그렇게 하면 head 는
  반드시 달라진다. 막는 것이 목적이 아니다. **리뷰를 거치지 않은 커밋이 있다는 사실을
  기록 없이 지나가지 않게 하는 것**이 목적이다.

  **`리뷰한 head:` 줄이 아예 없으면** 옛 형식의 코멘트다. 대조할 수 없으므로 통과로
  치지 말고, 그 사실을 말하고 사람의 판단을 받는다.

  두 층의 `Verdict` 는 그 코멘트 첫 줄에 있다. `Request changes` 가 해소되지 않았으면
  중단 — 사람이 그것을 넘기기로 했다면 그 사실을 3절에 적는다.

  라운드 코멘트를 못 찾으면 **리뷰가 돌지 않은 것이다.** 중단한다.

> 이 확인은 편의이지 강제가 아니다. 진짜 강제는 GitHub 브랜치 보호다
> (`common/ci/protect-branch.sh`). 브랜치 보호가 없는 레포라면 그 사실을 먼저 알린다.

## 3. 머지
`git log main..HEAD --format='%s'` 로 커밋 제목을 보고 사소한 것(리뷰수정·fixup·포맷)을 뺀
목록을 만든 뒤:

머지 **전에**, 사람이 무엇을 보고 정했는지를 PR 에 남긴다 — 머지 후에는 그 맥락을
복원할 곳이 없다. 리뷰가 남아 있는데 그것을 넘기고 머지하기로 했다면 특히 그렇다.

    gh pr comment <N> --body-file <파일>

내용은 세 줄이면 된다: 마지막 라운드의 두 `Verdict` · 사람이 넘기기로 한 지적이 있으면
그것과 이유 · `사람이 머지를 결정했다`.

`AI_KIT_SKILL=1 gh pr merge <N> --squash --delete-branch --body "<추린 목록, 없으면 빈 문자열>"`

접두어는 `use_skill` 훅을 통과시키는 표시다 — 없으면 훅이 막고 "merge-pr 을 호출하라" 고 답한다. 이미 그 안이다.

**훅을 지나도 권한 프롬프트는 뜬다.** `gh pr merge` 와 위의 `gh pr comment` 는 둘 다
`settings.json` 의 `ask` 에 있고, `ask` 규칙은 앞의 환경변수 대입을 지나 매치하므로
접두어로 비켜갈 수 없다. 사람이 승인할 때까지 기다린다 — 이 스킬 §전제 가 요구하는
"사람이 머지를 지시했다" 를 기계로 한 번 더 세우는 자리다.

`git branch -d` 를 따로 실행하지 않는다 — `--delete-branch` 가 처리한다.

## 4. main 복귀
`git checkout main` → `git pull --ff-only`.
fast-forward 실패 시 중단: `Error: main 을 fast-forward 할 수 없습니다.`

## 5. 한 줄 보고
`Merged PR #<N>. main at <short SHA>.`

이후 새 작업을 시작하지 않는다.
