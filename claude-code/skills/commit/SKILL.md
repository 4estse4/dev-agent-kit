---
name: commit
description: 스테이지된 변경에 Conventional Commits 메시지를 쓰고 커밋한다. 작은 논리 단위마다 한 번 — 한 브랜치는 여러 커밋을 쌓을 수 있다.
argument-hint: "[선택: 맥락·티켓]"
---

스테이지된 diff:
!`git diff --staged`

최근 커밋 (스타일 참조):
!`git log --oneline -10`

$ARGUMENTS

---

스테이지가 비었으면 중단: `Error: 스테이지된 변경이 없습니다.`

메시지 규칙:
- `<type>(<scope>): <명령형 요약>` — 72자 이내
- type: `feat` `fix` `refactor` `test` `docs` `chore` `perf` `ci` `build`
- **왜**가 자명하지 않을 때만 본문 문단을 추가한다. 무엇을 했는지는 diff 가 보여 준다.
- 공개 인터페이스가 호환되지 않게 바뀌면 `BREAKING CHANGE:` 푸터.
- 이슈의 일이면 본문 끝에 `Refs #N` 을 줄 머리에 적는다(이슈가 여럿이면 `Refs #N, #M`). 콜론은 붙이지 않는다(붙이면
  git 트레일러로 읽힌다). 트레일러(`Co-Authored-By:` 꼴)와는 빈 줄로 나눈다. 바로 위에 붙이면 git 이 `Co-Authored-By:` 를
  트레일러로 읽지 않는다. PR 이 열리기 전에는 다른 세션의 「다음 일」 목록이 이 줄과 줄 머리의 닫는 키워드(`Closes #N`
  꼴)로 그 이슈를 맡은 일로 알고 후보에서 뺀다. 브랜치의 커밋 어디에도 그런 줄이 없으면 커밋이 말하는 번호를 모두 맡은
  일로 본다.

커밋한다(`git commit`). **한 커밋 = 한 논리 변경.** 무관한 편집을 섞지 않는다.

> 메시지가 `--no-verify` 같은 git 플래그를 **언급**하면 권한 deny 패턴이
> 명령 전체 문자열을 보고 차단한다. 그럴 때는 파일로 전달한다:
> `git commit -F <file>`.
