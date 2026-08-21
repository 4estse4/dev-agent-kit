---
name: devlog
description: 이 브랜치의 작업을 docs/dev-log.md 항목으로 추가한다. 머지 직전에 실행한다.
argument-hint: "[선택: PR 번호]"
---

이 브랜치의 커밋:
!`git log --oneline main..HEAD`

변경 규모:
!`git diff main...HEAD --stat`

PR 본문과 리뷰:
!`[ -n "$ARGUMENTS" ] && gh pr view $ARGUMENTS --json title,body,comments --jq '"TITLE: \(.title)\n\n== BODY ==\n\(.body)\n\n== COMMENTS ==\n\(.comments[].body)"' 2>/dev/null || echo "(PR 번호 미지정)"`

기존 dev-log 항목 순서 (위치 판단용 — 첫 항목과 마지막 항목의 날짜를 비교한다):
!`grep -n '^## ' docs/dev-log.md 2>/dev/null | head -3; echo '   ...'; grep -n '^## ' docs/dev-log.md 2>/dev/null | tail -3`

기존 dev-log 마지막 항목 (형식 참조):
!`awk '/^## /{last=NR} END{print last}' docs/dev-log.md 2>/dev/null | xargs -I{} tail -n +{} docs/dev-log.md 2>/dev/null | head -25`

$ARGUMENTS

---

`docs/dev-log.md` 에 이번 작업 항목을 추가한다.

**위치는 기존 파일의 순서를 따른다** — 위 "기존 dev-log 최근 항목" 출력에서
날짜가 오름차순이면 파일 끝에, 내림차순이면 맨 위 항목 다음에 넣는다.
순서를 임의로 정하지 마라. 파일이 비어 있으면 오름차순(최신이 아래)으로 시작한다.

## 형식

```
## YYYY-MM-DD — <주제> (PR #N)

- **작업**: <무엇을 만들었나. 한두 줄.>
- **채택**: `[AI]` <제안> → 채택. <이유>
- **폐기**: `[AI]` <제안> → 폐기. `[사용자]` <무엇을 짚었나>
- **게이트가 잡은 것**: <린터·테스트·CI 가 잡은 것>
- **사람이 잡은 것**: <자동화가 못 잡아 사람이 발견한 것 + 어떻게 발견했나>
- **이관**: <안 하기로 한 것 + 어디에 기록했나>
```

## 규칙

- **화자를 반드시 표시한다** (`[AI]` `[사용자]` `[합의]`). 나중에 이 로그만 읽고
  협업 동학을 재구성할 수 있어야 한다 — 결론만 있으면 못 한다.
- **"게이트가 잡은 것" 과 "사람이 잡은 것" 을 나눈다.** 이게 쌓여야 검증 체계를
  데이터로 말할 수 있다. 해당 없으면 그 줄을 지운다(빈 줄로 두지 않는다).
- 해당 없는 항목은 **줄째로 지운다.** "없음" 을 채워 넣지 않는다.
- 리뷰에서 **보류·기각한 것도 짧게 남긴다.** 채택만 남기면 판단 과정이 사라진다.
- 항목 하나가 15줄을 넘으면 대개 과하다.
