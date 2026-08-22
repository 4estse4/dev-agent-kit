# Codex 바인딩

> **이 디렉터리에 설정 파일은 없다 — 의도된 것이다.**
>
> 한때 `config.toml` 스텁이 있었으나 지웠다. 공식 문서만 보고 쓴 것이라 실행 검증이 0
> 이었는데, 파일 형태로 존재하면 "쓸 수 있는 것"처럼 보여 조용히 안 먹히는 설정으로
> 시작하게 만든다. 킷 자신의 규칙 위반이기도 하다 — R4(문서가 약속한 강제는 실재해야
> 한다) · R5(적용 대상이 없는 규칙은 지운다).
>
> 아래 **개념 대응표는 유지한다.** 설정 스키마는 바뀌지만 "무엇이 어디에 사는가"는
> 잘 안 바뀌므로, 이쪽이 더 오래 쓸모 있다.

## 왜 이 바인딩이 존재하나

킷의 본체(`common/`)는 도구와 무관하다. 게이트·훅·CI·템플릿은 어떤 에이전트를 쓰든,
사람이 손으로 해도 그대로 작동한다. 도구에 묶이는 것은 이 얇은 층뿐이다.

조직에 전파할 표준이라면 한 도구에만 묶여선 안 된다 — 팀원마다 쓰는 도구가 다르다.

## 개념 대응

| 개념 | Claude Code | Codex |
| --- | --- | --- |
| 프로젝트 규칙 | `CLAUDE.md` (→ `AGENTS.md` 포인터) | **`AGENTS.md`** (그대로) |
| 설정 | `.claude/settings.json` | `.codex/config.toml` · `~/.codex/config.toml` |
| 훅 | `settings.json` 의 `hooks` | `hooks.json` 또는 `[hooks]` |
| 훅 이벤트 | `PreToolUse` `PostToolUse` `Stop` … | `PreToolUse` `PostToolUse` `SessionStart` `UserPromptSubmit` … |
| 스킬 | `.claude/skills/*/SKILL.md` | Skills (`skills.config`) |
| 서브에이전트 | `.claude/agents/*.md` | `[agents]` |
| 권한 | `permissions.allow` / `.deny` | `[permissions.<name>]` 프로파일 |

## 이 바인딩이 하지 않는 것

- **게이트를 다시 구현하지 않는다.** Codex 에서도 `.ai-kit/gate/gate.sh` 를 그대로 부른다.
- **규칙을 다시 쓰지 않는다.** `AGENTS.md` 하나가 두 도구 모두의 단일 출처다.

## 실제로 Codex 를 도입할 때 할 일

순서대로 셋이면 된다. **그때의 공식 문서로 스키마를 확인하면서** 한다.

1. **규칙은 손대지 않는다.** `AGENTS.md` 가 이미 Codex 가 읽는 형식이다
   (`common/templates/AGENTS.md` 에서 설치된다). 규칙을 두 벌로 만들지 마라.
2. **`.codex/config.toml` 을 만든다.** 위 대응표의 `[hooks]` · `[permissions.<name>]` 로
   Claude Code 바인딩(`claude-code/settings.json`)과 **같은 의도**를 옮긴다 —
   편집 후 자동 포맷, 그리고 게이트 우회·파괴적 조작 deny.
3. **게이트는 다시 구현하지 않는다.** Codex 에서도 `.ai-kit/gate/gate.sh` 를 그대로 부른다.

만들었으면 **실제로 돌려보고** 이 문서의 검증 상태를 갱신한다. 돌려보지 않은 설정을
커밋하지 마라 — 그게 이 디렉터리에서 파일을 지운 이유다.
