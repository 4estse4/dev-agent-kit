---
name: open-pr
description: 현재 feature 브랜치를 푸시하고 PR을 연다. 본문은 주장이 아니라 증거로 쓴다 — 검증 절의 명령 출력은 손으로 옮기지 않고 명령이 본문 파일에 덧붙인다.
argument-hint: "[선택: 맥락·티켓]"
---

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

## 차례

- [ripple.md](ripple.md) — 0. 파급을 직접 확인한다
- [body.md](body.md) — 2. PR 을 연다
- [round.md](round.md) — 3. 리뷰 한 라운드(3.1 ~ 3.4)
- [report.md](report.md) — 3.5 멈추고 사람에게 보고한다
- [next-round.md](next-round.md) — 3.6 다음 라운드
- [comment-format.md](comment-format.md) — 라운드 코멘트 형식

## 1. 푸시

    git push -u origin HEAD

