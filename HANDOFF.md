# HANDOFF — 새 세션에서 이어가기

새 Claude Code 세션을 이 레포에서 열고 **"HANDOFF.md 읽고 이어서 하자"** 라고 하면 된다.

---

## 이 레포가 왜 존재하나

`~/git/multimodal-asset-studio`(Vertex AI 멀티모달 과제, 2026-05 완료)를 **감사**한 결과물이다.
그 프로젝트는 절차·기록이 강했지만 **강제가 약했다** — 문서가 약속한 규칙 중 상당수가
기계로 확인되지 않고 사람의 성실성에 기대고 있었다.

이 킷은 그 감사에서 나온 결함을 **재사용 가능한 형태로** 고친 것이다.
목적: 다음 과제(카카오페이증권 사전 과제, 시작 후 7일) 첫날에 절차 셋업으로 시간을 안 쓰는 것.

## 감사에서 나온 것 → 킷의 대응

| 발견 | 대응 |
| --- | --- |
| PRD §5·§6 요구 4건(비용·원본프롬프트·seed·집계)이 **미구현인데 어디에도 안 잡혀 있었다** | `core/templates/SPEC.md` + `traceability.md` + `core/gate/trace.sh` (CI 검사) |
| 리뷰 체크리스트가 린터 일을 눈으로 함. 실제로 `errorlint` 3건을 AI 리뷰가 매번 `✓ OK` 로 넘김 | `core/lint/go/.golangci.yml` 풀세트 + `review-diff` 에서 해당 항목 삭제 |
| CLAUDE.md 가 "hook 으로 강제"라 했지만 하드룰 6개 중 **0개**가 강제됨 | `core/git-hooks/` + `AGENTS.md` 의 집행자 표기 규칙(R4) |
| `main` 브랜치 보호 없음 → CI 가 빨개도 머지 가능 | `core/ci/protect-branch.sh` |
| `pre_push.sh` 가 Claude Code 의 Bash 도구만 가로챔 (사람·다른 에이전트는 통과) | **강제를 에이전트 밖으로** — git hooks + CI |
| 커버리지 측정 자체가 없음 (worker 65.7%, vertex 70.3% — 가장 위험한 곳이 가장 낮음) | `core/ci/gates.yml` 의 coverage 잡 (보고 우선, `COVER_MIN` 설정 시 강제) |
| 리뷰 코멘트 6,500~11,000자, 그중 ~80%가 "문제없음"의 근거 서술 | 산출물 규칙 **R1** — 발견만 쓴다 |
| `review-diff` 가 `open-pr` 이 쓴 PR 본문을 **아예 안 읽음** → 주장이 검증 안 됨 | 산출물 규칙 **R3** + `review-diff` 가 본문을 대조 대상으로 수집 |
| `.env.example` 의 `DAILY_BUDGET_USD`·`VERTEX_REGION_*` 가 죽은 설정 | (미대응 — 아래 "남은 것") |
| 시크릿·취약점 스캔 0 | `core/gate/secrets.sh` + CI 의 govulncheck·npm audit |
| ADR 15개/5일 · ceremony 과다로 빌드 시간 ~20% 소모 | `core/templates/adr.md` 상단의 **"쓴다/쓰지 않는다" 기준** |

## 설계 원칙 세 개 (모든 결정의 근거)

1. **강제는 에이전트 밖에 둔다.** git hooks·CI·브랜치 보호는 도구를 바꿔도, 사람이 손으로 해도 작동한다.
2. **아래 계층이 잡을 수 있으면 위 계층에서 뺀다.** 린터가 잡는 걸 AI 리뷰에 맡기지 않는다.
3. **못 찾은 것은 쓰지 않는다.** AI 산출물은 부피로 신뢰를 사칭한다.

전문: `core/docs/artifact-rules.md`(R1~R6) · `core/docs/verification-layers.md`(L1~L3)

## 구조

| | |
| --- | --- |
| `operator/` | **머신 단위** → `~/.claude/`. statusline·전역 정책·전역 설정·goal 스킬 |
| `core/` | **프로젝트 단위** → 대상 레포. 게이트·훅·린터·CI·템플릿·설계 문서 |
| `bindings/` | **도구 단위**. `claude-code/`(검증됨) · `codex/`(형식만 확인) |

규칙의 단일 출처는 `AGENTS.md`(중립 표준). `CLAUDE.md` 는 포인터 한 줄.

## 검증된 것 (실측)

- `main` 직접 커밋 차단 · 시크릿 커밋 차단 · 깨진 코드 push 차단 — **순수 `git` 명령으로 확인**(에이전트 없이)
- 게이트가 실 2언어 모노레포에서 44초, 출력 2줄
- `trace.sh` 가 누락·유령·없는 경로 3종 검출
- 신원 불일치 검출 (`t@t` vs 설정값)
- 새 린터 설정을 실제 백엔드에 적용 → **14건 검출**(errorlint 3 · errchkjson 2 · gosec 9)

## 남은 것

1. **`bindings/codex/config.toml` 실사용 검증** — 현재 형식만 확인, 미검증 표시해 둠
2. **`core/ci/gates.yml` 실제 CI 실행 검증** — 아직 어떤 레포에서도 돌려보지 않음
3. **multimodal-asset-studio 에 킷 적용** (선택) — 킷 검증 + 실제 결함(errorlint 3건) 수정
4. `.env.example` ↔ config 정합 테스트 (죽은 설정값 부류를 기계로 닫기)
5. e2e 스캐폴드 + "언제 e2e 를 쓸지" 판단 기준
6. 검증 이력 측정표 (어느 계층이 무엇을 잡았나 — dev-log 템플릿에 자리는 만들어 둠)

## 작업 규칙

- 이 레포는 아직 자기 자신에게 킷을 설치하지 않았다(닭과 달걀). 설치할지 결정할 것.
- 커밋 신원: `Minwoo Kwak <mwkwak.work@gmail.com>` — `~/.gitconfig` 의 `includeIf` 로 자동 적용됨.
- GitHub squash 머지 커밋은 계정 전역 설정을 따르므로 `4est <...@users.noreply.github.com>` 로 찍힌다.
  로컬 신원을 main 에 남기려면 GitHub 머지 버튼 대신 로컬에서 머지해야 한다.
