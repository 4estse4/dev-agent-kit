---
name: review-diff
description: PR 또는 현재 브랜치의 diff를 리뷰한다. 발견한 것만 기록하고, PR 본문의 주장을 diff와 대조한다. 기계가 잡는 것은 리뷰하지 않는다.
argument-hint: "[PR 번호 | 비우면 현재 브랜치]"
---

Diff:
!`gh pr diff $ARGUMENTS 2>/dev/null || git diff main...HEAD`

변경 파일:
!`gh pr diff $ARGUMENTS --name-only 2>/dev/null || git diff main...HEAD --name-only`

**PR 본문 (검증 대상 — 배경이 아니다):**
!`[ -n "$ARGUMENTS" ] && gh pr view $ARGUMENTS --json title,body --jq '"TITLE: \(.title)\n\n\(.body)"' 2>/dev/null || echo "(로컬 브랜치 리뷰 — 본문 없음)"`

메타데이터:
!`[ -n "$ARGUMENTS" ] && gh pr view $ARGUMENTS --json headRefOid,headRepository --jq '"PERMALINK_BASE=https://github.com/\(.headRepository.nameWithOwner)/blob/\(.headRefOid)/"' 2>/dev/null || true`

---

## 리뷰하지 않는 것 (기계가 이미 잡는다)

아래는 린터·타입체커·테스트가 결정론적으로 잡는다. **리뷰에서 언급하지 마라.**
언급하고 싶어지면 그건 린터 설정이 빠졌다는 뜻이니, 리뷰가 아니라 설정을 고쳐라.

포맷 · 임포트 정렬 · 미사용 변수 · `%w` 래핑 누락 · body/rows/파일 close 누락 ·
context 전파 · 루프변수 캡처 · `any` 사용 · 훅 규칙 · 접근성 속성 · 알려진 취약 패턴

## 리뷰하는 것

1. **본문 ↔ diff 대조** — 본문이 말한 변경이 실제로 diff에 있나. "Tests run"에 적힌
   테스트가 실제로 존재하나. "Risks: None"이 맞나. **불일치는 그 자체로 발견이다.**
2. **응집도** — 이 diff가 한 가지 일을 하나. 무관한 변경이 섞였나.
3. **테스트 케이스 선택** — 커버리지 숫자가 아니라, *의미 있는* 경로를 덮나.
   에러 경로·경계값·동시 실행이 빠졌나. 삭제된 테스트가 있나.
4. **에러 분류** — 재시도 가능/불가 구분이 맞나. 삼켜진 실패가 있나.
5. **동시성·자원 수명** — goroutine·구독·타이머가 취소되고 종료되나.
6. **의도를 드러내는 이름** — 범위·타입·동작을 오해하게 하는 이름.
7. **투기적 추상화** — 지금 필요 없는 seam·필드·설정.
8. **프로젝트 규칙** — `CLAUDE.md` 의 하드룰 위반.

## 출력 형식 (엄수)

**못 찾은 것은 쓰지 않는다.** 항목별로 "✓ 문제없음"과 그 근거를 쓰지 마라 —
검증 불가능한 서술이고, 읽는 사람의 시간을 쓰면서 신뢰를 사칭한다.

```
## Review

checked: 본문대조 · 응집도 · 테스트 · 에러분류 · 동시성 · 명명 · 추상화 · 규칙

### 본문 ↔ diff
<불일치만 적는다. 일치하면: "일치.">

### 발견
1. [높음|중간|낮음] `path/file.go:120` — <한 줄 요약>
   <왜 문제인가 1~2문장. 반드시 구체적 실패 시나리오를 포함한다:
    어떤 입력·상태에서 무엇이 잘못되나.>

### 남기는 위험
- <머지해도 되지만 알고 있어야 할 것. 없으면 이 절 자체를 생략.>

**Verdict**: Approve | Request changes | Comment — <한 문장>
```

규칙:

- 발견이 0건이면 `### 발견` 아래에 `없음.` 한 줄. 그것으로 끝이다.
- **구체적 실패 시나리오를 못 쓰겠으면 그것은 발견이 아니라 취향이다** — 적지 마라.
- 코드 위치는 `PERMALINK_BASE<path>#L<line>` 로 링크한다(PERMALINK_BASE 가 있을 때만).
- 리뷰 전체가 화면 한 장을 넘으면 대부분 R1 위반이다. 줄여라.

---

**GitHub 게시** (`$ARGUMENTS` 가 비어 있으면 이 블록 전체를 건너뛴다):

`gh pr comment $ARGUMENTS --body "<위에서 쓴 리뷰>"`

Verdict 가 **Request changes** 일 때만 추가로:
`gh pr review $ARGUMENTS --request-changes --body "<한 줄 요약>"`
