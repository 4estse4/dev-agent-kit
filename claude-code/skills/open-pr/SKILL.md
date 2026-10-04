---
name: open-pr
description: 현재 feature 브랜치를 푸시하고 PR을 연다. 본문은 주장이 아니라 증거로 쓴다 — 검증 절의 명령 출력은 손으로 옮기지 않고 명령이 본문 파일에 덧붙인다.
argument-hint: "[선택: 맥락·티켓]"
---

## 꼭 지킬 것

**단계를 시작하기 전에 아래 「차례」에서 그 단계의 파일을 읽는다.** 이 파일에는 차례와 늘 지킬 것만 있고,
단계마다 할 일과 그 까닭은 그 파일에 있다.

**컴팩션 뒤에는 진행 중인 단계의 파일을 다시 읽는다.** 컴팩션 뒤에는 이 파일의 앞부분만 다시 붙고,
읽어 둔 보조 파일은 요약되어 절차가 빠질 수 있다.

**열기 전에 제목과 본문 전문을 사람에게 보이고 승인받는다.** 보인다는 것은 승인을 묻기 바로 전에 세션의
응답에 그 글의 최종본 전문을 출력하는 것이다 — 파일 경로나 요약으로 대신하지 않는다. 이 스킬에서 승인을
받는 글은 모두 그렇다.

라운드 중에는 커밋도 푸시도 본문 수정도 하지 않는다 — 두 리뷰가 서로 다른 것을 본다.

다음 라운드를 진행하는 것도, 머지하는 것도 **사람이 정한다.**

**푸시는 3.6 의 5 셈이 `1` 이상일 때만 한다.**

**본문은 손대지 마라.** 라운드가 만든 것은 코멘트에 쌓이고, 최종 정리는 `merge-pr` 이 머지
직전에 코멘트 하나로 올린다. 근거는 `docs/process/verification-stages.md` 4.

## 차례

- [ripple.md](ripple.md) — 0. 파급을 직접 확인한다
- [body.md](body.md) — 2. PR 을 연다
- [round.md](round.md) — 3. 리뷰 한 라운드(3.1 ~ 3.4)
- [report.md](report.md) — 3.5 멈추고 사람에게 보고한다
- [next-round.md](next-round.md) — 3.6 다음 라운드
- [comment-format.md](comment-format.md) — 라운드 코멘트 형식

이 브랜치의 커밋:
!`git log --oneline main..HEAD`

변경 규모:
!`git diff main...HEAD --stat`

> `!! 새 테스트가 …개라` 가 출력되면 위 목록은 앞부분뿐이다 — 본문의 `새 테스트` 칸에
> 그 사실을 적는다. 목록에 없는 것을 "없다" 로 쓰지 마라.

**게이트 실행 결과 (열어도 되는지 보는 것이다. 본문에는 2절의 `evidence.sh` 로 다시 실행해 덧붙인다):**
!`bash .kit/gate/gate.sh 2>&1 || true`

새로 추가된 테스트:
!`git diff main...HEAD -U0 -- '*_test.go' '*.test.ts' '*.test.tsx' '*_test.py' | grep -E '^\+\s*(func Test|it\(|test\(|describe\()' | sed 's/^+[[:space:]]*/  /' | head -40; _t=$(git diff main...HEAD -U0 -- '*_test.go' '*.test.ts' '*.test.tsx' '*_test.py' | grep -cE '^\+\s*(func Test|it\(|test\(|describe\()'); [ "$_t" -gt 40 ] && echo "  !! 새 테스트가 ${_t}개라 위는 앞 40개뿐이다"`

$ARGUMENTS

---

`git log main..HEAD` 가 비면 중단: `Error: 이 브랜치에 커밋이 없습니다.`

## 1. 푸시

    git push -u origin HEAD

