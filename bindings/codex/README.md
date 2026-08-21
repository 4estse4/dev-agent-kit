# Codex 바인딩

> **검증 상태: 형식만 확인.** OpenAI 공식 문서(2026-08 확인)로 기능 존재와 파일 위치는
> 확인했으나 **실사용으로 검증하지 않았다.** 쓰기 전에 현재 문서로 스키마를 다시 확인할 것.
> 검증 안 된 것을 검증된 것처럼 두면 킷 전체의 신뢰가 깎인다(산출물 규칙 R2).

## 왜 이 바인딩이 존재하나

킷의 본체(`core/`)는 도구와 무관하다. 게이트·훅·CI·템플릿은 어떤 에이전트를 쓰든,
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

## 설치

`AGENTS.md` 는 `core/templates/AGENTS.md` 에서 온다(도구 무관이라 core 에 있다).
Codex 쪽에서 추가로 필요한 것은 `.codex/config.toml` 뿐이다 — 아래 stub 참조.
