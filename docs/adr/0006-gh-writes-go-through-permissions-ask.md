# ADR-0006: gh 쓰기 명령은 훅이 아니라 `permissions.ask` 로 사람의 확인을 받는다

- **상태**: 채택
- **날짜**: 2026-09-08 (PR #48)

## 맥락

킷을 설치한 프로젝트 하나에서 PR 한 건에 리뷰 라운드가 스무 번 돌았고, 그 사이 사람의
승인은 한 번도 없었다. 사고의 경위는 `docs/dev-log.md` 의 2026-09-08 항목에 있다. 여기
적는 것은 그 사고를 닫으며 **어디에 강제를 둘지** 정한 것이다.

세 겹이 다 열려 있었다. 스킬이 라운드 끝에서 멈추지 않았고, 규칙 문서의 승인 목록에
리뷰 라운드가 없었고, `settings.json` 의 `allow` 에 `Bash(gh pr comment*)` 가 있어 마흔
번 게시하는 동안 권한 프롬프트가 한 번도 안 떴다.

그 자리에 있던 것이 `use_skill.sh` 훅이다. 셸 명령 문자열을 정규식으로 파싱해 `gh` 쓰기
명령을 막았다. **못 잡는 형태 넷을 스스로 적어두고 "안 고치기로 정했다" 고 못 박았고**,
스킬만 통과시키려는 탈출구 `AI_KIT_SKILL=1` 이 스킬 파일에 평문으로 적혀 있어 에이전트가
읽고 붙일 수 있었다. 훅으로 확인할 수 있는 것은 "스킬을 거쳤나" 이고, 확인해야 하는 것은
"사람이 봤나" 다. 후자는 `permissions.ask` 가 하고, 전자는 탈출구 때문에 못 한다.

그 자리의 공식 답은 Claude Code 문서 `auto-mode-config` 의 「Add a human checkpoint」이고,
예시로 든 규칙이 `Bash(gh pr create *)` 다.

같은 작업에서 근거 하나가 틀린 채로 들어갔다가 잡혔다. "서브에이전트가 부모 세션의
권한 규칙을 물려받는지는 확인되지 않았다" 를 콜드 리뷰어가 직접 게시하지 않는 이유로
적었는데, 공식 문서는 반대였다:

```
tools-reference:  Launching the subagent doesn't itself prompt for permission.
                  Claude Code checks the subagent's own tool calls against your
                  permission rules as it runs.
permissions:      Use `Agent(AgentName)` rules to control which subagents Claude
                  can use … Add these rules to the `deny` array
```

서브에이전트도 권한 규칙을 지나고, `Agent(...)` 는 `deny` 로 쓰는 규칙이며 스폰 자체는
프롬프트를 안 띄운다. 게시를 메인 한 자리로 모으는 이유는 따로 있었고(사람이 한
자리에서 읽는다 · 요약이 코멘트의 본체가 되려면 한 자리여야 한다) 그것만으로 충분하다.
근거를 적어둔 자리들만 고쳤다.

## 결정

- **`use_skill.sh` 를 걷어낸다.** 이 훅은 `main` 에 도달한 적이 없다 — 한 브랜치가 만들고
  같은 브랜치가 지웠다. 릴리스된 킷이 그 훅을 설치한 프로젝트는 없다.
- **밖으로 나가는 `gh` 쓰기 명령을 `settings.json` 의 `permissions.ask` 에 둔다.** PR #48
  이 아홉을 뒀고 그 뒤 PR 이 `git branch -D*` 하나를 더했다. 그 PR 도중의 기록에는 넷이라
  적혀 있었고, 머지된 것은 아홉이다. 횟수를 제한하지 않는다 — 매번 사람 눈에 띄게 할
  뿐이고, 세는 것은 사람이다.
- **두 리뷰는 게시하지 않고 돌려준다.** 게시는 `open-pr` 의 한 자리다.

이 ADR 을 쓰며 확인한 지금 목록:

```
$ python3 -c "import json;[print(x) for x in json.load(open('claude-code/settings.json'))['permissions']['ask']]"
Bash(gh pr create*)
Bash(gh pr merge*)
Bash(gh pr comment*)
Bash(gh pr review*)
Bash(gh issue create*)
Bash(gh issue comment*)
Bash(gh issue close*)
Bash(git branch -D*)
Bash(gh pr edit*)
Bash(gh api*)
```

## 대안과 기각 사유

| 대안 | 기각 사유 |
| --- | --- |
| `use_skill.sh` 훅을 고쳐 쓴다 | 셸 문자열 파싱은 못 잡는 형태를 스스로 인정했고, 탈출구가 스킬 파일에 평문이다. 훅이 확인하는 것은 "스킬을 거쳤나" 이지 "사람이 봤나" 가 아니다 |
| 콜드 리뷰어가 직접 게시한다 | 사람이 두 리뷰를 한 자리에서 읽어야 하고, 요약이 코멘트의 본체가 되려면 한 자리여야 한다. "권한을 우회한다" 는 이유는 틀렸으므로 근거에서 뺐다 |
| `Agent(...)` 를 `ask` 에 넣는다 | `ask` 에 넣어도 스폰에는 프롬프트가 안 뜬다. `Agent(...)` 는 `deny` 용이다 |
| 같은 head 에서 두 번째 라운드를 훅으로 거부한다 | 라운드마다 head 가 움직이므로(서로 다른 head 스무 개) 이 사고를 한 번도 못 막는다. 그 프로젝트의 스킬 자체가 매 라운드 push 를 요구한다 |

## 결과

프롬프트로 사람이 확인할 수 있는 것은 **명령까지**다. `gh pr merge` 는 명령이 곧 내용이라
프롬프트에 다 보이지만, `--body-file` 로 넘기는 코멘트와 본문은 프롬프트에 파일 경로만
보인다. 그래서 **초안을 사람에게 보이고 승인받는 단계**가 따로 생겼다(PR #64).
어느 행동이 그 승인을 받는지는 `common/docs/verification-stages.md` 6.3 에 있고, 규칙이
무엇을 막는지 실행해 확인한 기록은 6.2 에 있다.

**`use_skill.sh` 를 다시 넣지 마라.** 이 레포에서는 킷의 `settings.json` 이 로드되지 않으므로
(이슈 #4) `ask` 도 여기서는 안 뜬다. 승인은 사람이 초안을 보는 단계가 맡는다.

**셸 문자열을 읽는 훅이 이슈 #83 에서 하나 들어왔다 — `round_comment_quotes.sh`.** 라운드
코멘트의 승인을 떼면서, 그 코멘트의 `(사람)` 인용이 그 PR 의 3.5 코멘트에 있는지를 본다. 이
레포도 `.claude/settings.json` 으로 이 훅 하나만 건다. `use_skill.sh` 를 기각한 이유와 견주면
이렇다.

- 확인하는 것이 다르다. 「스킬을 거쳤나」가 아니라 「인용이 사람이 승인한 3.5 코멘트에
  있나」다.
  「사람이 봤나」는 여전히 `ask` 와 초안을 보이는 단계가 맡고, `ask` 의 `gh pr comment` 는
  그대로다
- 탈출구가 없다. 환경변수나 표시로 끄는 길을 두지 않았다
- 못 잡는 형태가 있는 것은 같다. `gh api` · `gh issue comment <PR 번호>` 로 올리거나 게시
  명령을 스크립트 파일에 두고 돌리거나 인라인 인터프리터에 인자 목록으로 넘기면 안 걸리고,
  훅 머리에 적었다. 받아들인 이유는 비켜 간 것이 라운드 코멘트라는 것이다 — 다음 라운드가 고치는 글이고, 되돌릴 수 없는 것은 여전히 권한 규칙과
  git 훅 · CI 가 막는다
- 게시인지 가리지 않는다. PR #94 의 1 · 2 · 3 · 4라운드에서 게시를 해석해 가리려 할 때마다
  새 우회가 났다(줄바꿈 · heredoc · `\` 줄넘김 · 주석 · 붙인 짧은 플래그 · 하위 명령 앞의 `-R`).
  3라운드까지는 「게시로 알아본 것만 막는다」여서, 못 알아본 게시가 대조 없이 지나갔다.
  「명령 자리」를 목록으로 정해 보니 목록 밖(`if` · `timeout` · `bash -lc` · `find -exec`)의
  게시가 또 지나갔다. 그래서 명령 글자 어디에든 `gh pr comment` 가 보이면 따옴표 · heredoc
  안이라도 한 줄 정규형(`--body-file <절대 경로>`)일 때만 받고, 나머지는 게시인지 가리지 않고
  막는다. 그 글자를 품은 검색 · 커밋 메시지 · heredoc 이 게시가 아니어도 막히는 것은 대가로
  받아들였다. `use_skill.sh` 가 못 잡는 형태를 적어 두고 그대로 둔 것과 다른 점이 이것이다.
  남는 것은 명령 이름을 꾸민 것(변수 · 별칭 · 낱말 안의 따옴표나 `\`) · 스크립트 파일 ·
  인라인 인터프리터의 인자 목록이고, 이 훅이 겨누는 것은 작정한 우회가 아니라 형식대로 친
  게시의 실수다

되돌리려면 `settings.json` 의 `ask` 와 `verification-stages.md` 의 그 표를 같이 건드려야
한다.
