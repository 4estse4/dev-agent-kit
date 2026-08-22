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

자세한 근거: [`common/docs/artifact-rules.md`](common/docs/artifact-rules.md) ·
[`common/docs/verification-layers.md`](common/docs/verification-layers.md)

## 구조

```
common/                에이전트 없이도 작동하는 것 — 킷의 본체
  docs/                산출물 규칙(R1~R7) · 검증 계층 (설계 근거)
  templates/           AGENTS.md · SPEC · 추적 매트릭스 · ADR · dev-log · plan · PR
  git-hooks/           pre-commit · pre-push  ← 진짜 강제가 사는 곳
  gate/                게이트 본체 + 언어별 어댑터
  lint/                언어별 린터 설정 (하드룰을 린트 규칙으로 코드화)
  ci/                  게이트 · 시크릿 스캔 · 취약점 스캔 워크플로

claude-code/           Claude Code 가 있어야 의미 있는 것
  settings.json · hooks/ · skills/ · agents/ · statusline-command.sh

codex/                 개념 대응표 + 도입 절차 (설정 파일 없음 — 의도된 것)
```

**`common/` 은 에이전트 없이도 작동한다** — git·CI·린터·사람이 그대로 실행한다.
에이전트가 있어야 의미 있는 것만 도구 이름 디렉터리로 간다. 트리를 보면 도구 디렉터리가
둘뿐이고 나머지가 전부 `common/` 이라는 게 드러나는데, 그것이 **설계 원칙 1의 시각적 증거**다.

**테마·터미널 표시 모드·모델·effort 같은 개인 취향은 킷이 다루지 않는다.**
`/config` 나 `~/.claude/settings.json` 에서 각자 정한다 — 킷이 박으면 개발자의
`/model` 선택을 무력화한다.

이어서 작업하려면 [`HANDOFF.md`](HANDOFF.md) 를 읽는다.

### 규칙의 단일 출처는 `AGENTS.md`

`AGENTS.md`는 Agentic AI Foundation(Linux Foundation) 산하 중립 표준이고
Codex · Cursor · Cline · Windsurf · Gemini CLI가 같은 형식을 읽는다.
그래서 **프로젝트 규칙은 `AGENTS.md`에 한 번만 쓰고**, `CLAUDE.md`는 그것을
가리키는 얇은 파일로 둔다. 규칙이 도구별로 갈라지지 않는다.

## 검증 상태 (정직하게)

| 부분 | 상태 |
|---|---|
| `common/` 전부 | **검증됨** — 실제 프로젝트에 적용해 결함을 잡음 |
| `codex/` | **개념 대응표만** — 설정 파일은 두지 않는다(미검증 스텁 제거). 도입 절차는 그 README 에 |
| `claude-code/` 의 statusline | **검증됨** — 상시 사용 중 |

## 누가 썼나 (정직하게)

이 레포의 코드·문서는 **전부 Claude 가 작성했다.** 사람은 방향 설정 · 범위 결정 ·
리뷰 · 수용 여부를 맡았고 일부를 직접 수정했다.

어느 모델이 어떤 effort 로 썼는지는 **커밋마다** 적혀 있다:

```
Co-Authored-By: Claude Opus 5 (xhigh) <noreply@anthropic.com>
```

문서에 한 줄로 적지 않고 커밋에 적는 이유는 비대칭이다. 기록 비용은 커밋당 ~20자인데
**미기록 비용은 영구 복구 불가**다 — 모델이나 effort 를 바꿔 결과를 비교하려는 시점이
오면 이전 커밋의 귀속은 이미 사라졌고, 머지된 히스토리에는 소급할 수 없다.
지금까지의 분포는 이렇게 센다:

```bash
git log --format='%(trailers:key=Co-Authored-By,valueonly)' \
  | sed -n 's/.*(\([^)]*\)).*/\1/p' | sort | uniq -c
```

> 이 킷의 전제는 "AI 가 썼으니 못 믿는다"도 "AI 가 썼으니 빠르다"도 아니다.
> **누가 썼든 기계로 확인되지 않은 것은 확인되지 않은 것**이라는 쪽이다.
> 그래서 강제를 에이전트 밖에 두고(원칙 1), 검증 상태를 위 표처럼 적는다.

## 쓰는 법

```bash
git clone <this-repo> ~/git/ai-native-kit        # 킷은 아무 데나 한 번만
~/git/ai-native-kit/install.sh ~/work/myproj     # 대상 프로젝트에 설치
```

**대상 경로는 필수다.** 현재 레포에 설치하려면 `.` 를 준다. 이 명령은 파일 30개 가까이를
쓰고 git config 를 바꾸므로, 어디에 쓰는지 추측하지 않는다 — `cd` 를 빠뜨려 엉뚱한 레포에
설치하는 사고가 실제로 있었다.

설치되는 강제 계층:

| 계층 | 막는 것 |
|---|---|
| `pre-commit` (git) | `main` 직접 커밋 · 시크릿 패턴 |
| `pre-push` (git) | 변경 영역의 포맷·린트·타입·테스트 실패 |
| CI | 위 전부 + 커버리지 + 시크릿 스캔 + 취약점 스캔 |
| 브랜치 보호 | 위를 통과 못 한 머지 |

## 킷이 바뀌면 — 갱신

```bash
<kit>/install.sh <경로> --update --dry-run   # 무엇이 바뀔지만 본다
<kit>/install.sh <경로> --update             # 자동 병합, 충돌만 보고
```

설치할 때 킷 원본을 `.ai-kit/baseline/` 에 남겨두고, 갱신할 때 그것을 base 로 3-way
병합한다. **프로젝트가 고친 곳과 킷이 바꾼 곳이 겹치지 않으면 둘 다 살아남는다.**
겹치면 충돌 마커를 파일에 남긴다 — 에디터와 git 이 그대로 다루는 형식이라 새 도구를
배울 필요가 없다. 해소한 뒤 `--update` 를 다시 돌려야 baseline 이 맞춰진다.

| 대상 | 갱신 방식 |
|---|---|
| `.ai-kit/gate/` · `git-hooks/` | 킷 소유 — 통째로 교체 (프로젝트가 고치면 CI 체크섬이 잡는다) |
| `AGENTS.md` · CI · 린터 · 스킬 | 프로젝트 소유 — 3-way 병합 |

낡았는지는 `SessionStart` 훅이 한 줄로 알린다. CI 가 아니라 로컬인 이유: CI 에서 하려면
러너가 킷 레포를 읽어야 하고, 킷이 private 이면 secrets 에 토큰을 넣어야 한다.
**낡음 감지는 정확성 게이트가 아니라 편의다** — 놓쳐도 깨지지 않고 옛 킷 코드를 쓸 뿐이다.
그 정도에 보안 표면을 늘리지 않는다.

## 무엇이 공유되고 무엇이 프로젝트 소유인가

| | 소유 | 이유 |
|---|---|---|
| `.ai-kit/gate/*` | **킷** (vendor·버전 기록) | 게이트 정의는 한 곳이어야 로컬·CI 가 어긋나지 않는다 |
| `.github/workflows/gates.yml` | **프로젝트** (시작 템플릿) | 서비스 컨테이너·시크릿 등 CI 요구는 본질적으로 프로젝트마다 다르다 |
| `.golangci.yml` · `eslint.config.js` | **프로젝트** (시작 템플릿) | 하드룰이 프로젝트마다 다르다 |

워크플로가 프로젝트 소유여도 **게이트 명령은 복붙하지 않는다** — `gate.sh` 를 부른다.
프로젝트가 플래그를 더 줘야 하면 확장점(`AI_KIT_GO_TEST_FLAGS` 등)을 쓴다.
