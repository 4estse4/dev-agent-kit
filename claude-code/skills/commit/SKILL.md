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
- **왜**가 자명하지 않을 때만 본문 문단을 추가한다. 무엇을 했는지는 diff 가 말한다.
- 공개 인터페이스가 깨지면 `BREAKING CHANGE:` 푸터.

커밋한다(`git commit`). **한 커밋 = 한 논리 변경.** 무관한 편집을 섞지 않는다.

> 메시지가 `--no-verify` 같은 git 플래그를 **언급**하면 권한 deny 패턴이
> 명령 전체 문자열을 보고 차단한다. 그럴 때는 파일로 넘긴다:
> `git commit -F <file>`.
