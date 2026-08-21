# ai-native-kit

AI 코딩 에이전트와 함께 개발할 때 쓰는 **절차·검증 체계 킷**.
새 프로젝트에 clone 해서 `install.sh` 한 번 돌리면 게이트·훅·템플릿·스킬이 선다.

## 설계 원칙 세 개

1. **강제는 에이전트 밖에 둔다.**
   git hooks · CI · 브랜치 보호는 어떤 에이전트를 쓰든, 사람이 손으로 해도 작동한다.
   에이전트 훅에만 강제를 걸면 도구를 바꾸는 순간 강제가 사라진다.
   → 에이전트 훅은 *편의*(자동 포맷·조기 피드백)에만 쓴다.

2. **아래 계층이 잡을 수 있으면 위 계층에서 뺀다.**
   린터가 결정론적으로 잡는 것을 AI 리뷰에 맡기지 않는다.
   리뷰 체크리스트에서 그만큼 삭제하면 **품질이 오르면서 리뷰가 짧아진다.**

3. **못 찾은 것은 쓰지 않는다.**
   AI 산출물은 부피로 신뢰를 사칭한다. 검증 산출물은 발견만 기록하고,
   본 범위는 한 줄로 선언한다.

자세한 근거: [`core/docs/artifact-rules.md`](core/docs/artifact-rules.md) ·
[`core/docs/verification-layers.md`](core/docs/verification-layers.md)

## 구조

```
operator/              머신 단위 — ~/.claude 에 설치. 한 번만.
  statusline-command.sh  세션 상태(리밋·컨텍스트·effort·PR) 한 줄 표시
  CLAUDE.md              모든 프로젝트에 적용되는 작업 정책
  settings.json          모델·effort·statusline 기본값

core/                  프로젝트 단위 — 이 킷의 본체
  docs/                산출물 규칙 · 검증 계층 (설계 근거)
  templates/           SPEC · 추적 매트릭스 · ADR · dev-log · plan · PR 템플릿
  git-hooks/           pre-commit · pre-push  ← 진짜 강제가 사는 곳
  lint/                언어별 린터 설정 (하드룰을 린트 규칙으로 코드화)
  ci/                  게이트 · 시크릿 스캔 · 취약점 스캔 · 배포 워크플로

bindings/              에이전트별 바인딩 — 개념은 같고 형식만 다르다
  claude-code/         settings.json · hooks/ · skills/ · agents/
  codex/               config.toml (형식만 확인 · 미검증)
```

이어서 작업하려면 [`HANDOFF.md`](HANDOFF.md) 를 읽는다.

### 규칙의 단일 출처는 `AGENTS.md`

`AGENTS.md`는 Agentic AI Foundation(Linux Foundation) 산하 중립 표준이고
Codex · Cursor · Cline · Windsurf · Gemini CLI가 같은 형식을 읽는다.
그래서 **프로젝트 규칙은 `AGENTS.md`에 한 번만 쓰고**, `CLAUDE.md`는 그것을
가리키는 얇은 파일로 둔다. 규칙이 도구별로 갈라지지 않는다.

## 검증 상태 (정직하게)

| 부분 | 상태 |
|---|---|
| `core/` 전부 | **검증됨** — 실제 프로젝트에 적용해 결함을 잡음 |
| `bindings/claude-code/` | **검증됨** — 상시 사용 |
| `bindings/codex/` | **형식만 확인** — 공식 문서 기준으로 작성, 실사용 미검증. 쓰기 전 확인 필요 |
| `operator/` | **검증됨** — 상시 사용 중인 설정을 캡처 |

## 쓰는 법

```bash
git clone <this-repo> && cd <target-project>
<kit>/install.sh            # 훅 설치 · 템플릿 복사 · 브랜치 보호 설정
```

설치되는 강제 계층:

| 계층 | 막는 것 |
|---|---|
| `pre-commit` (git) | `main` 직접 커밋 · 시크릿 패턴 |
| `pre-push` (git) | 변경 영역의 포맷·린트·타입·테스트 실패 |
| CI | 위 전부 + 커버리지 + 시크릿 스캔 + 취약점 스캔 |
| 브랜치 보호 | 위를 통과 못 한 머지 |
