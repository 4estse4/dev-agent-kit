# 이 킷이 무엇을 하고, 무엇을 안 하나

설치 직후 한 번 읽는 문서다. **킷이 자동으로 해주는 것 · 네가 채워야 하는 것 ·
킷이 아직 못 하는 것**을 구분한다. 구분이 없으면 안 되는 것을 된다고 믿게 된다.

## 1. 자동으로 도는 것 — 손댈 것 없음

| 시점 | 무엇 | 막나 |
|---|---|---|
| 파일 편집 직후 | 포맷(gofmt·prettier·ruff·ktlint) | **못 막는다** — 도구가 이미 실행된 뒤라 구조적으로 불가. 포매터가 없으면 알린다 |
| `git commit` | 보호 브랜치 · 커밋 신원 · 충돌 마커 · 시크릿 · **린트** | 막는다 |
| `git push` | 위 + 타입 · 테스트 · 빌드 | 막는다 |
| CI | 같은 게이트 + 커버리지 · 취약점 스캔 · 요구 추적 | **우회할 수 없다.** 다만 머지 자체는 브랜치 보호를 켜야 막힌다 |

**도구가 없으면 검사는 실패한다.** 도구 부재는 통과가 아니라 "검사되지 않았다" 이고,
로컬만 관대하면 로컬 통과가 CI 에서 실패해 왕복 비용을 문다.

```bash
bash .ai-kit/gate/install-tools.sh              # 이 레포에 필요한 것만 설치
bash .ai-kit/gate/gate.sh --lint                # 린트만 (커밋 훅이 부르는 것)
bash .ai-kit/gate/gate.sh --all                 # 전부 (CI 가 부르는 것)
```

불가피할 때만 `AI_KIT_ALLOW_MISSING_TOOLS=1` 로 내린다. **무엇이 검사되지 않는지 출력된다.**

## 2. 네가 채워야 하는 것 — 안 채우면 값을 못 한다

| 파일 | 무엇을 | 안 채우면 |
|---|---|---|
| `CLAUDE.md` 의 `<프로젝트명>` | 이름 | 표시만 어색 |
| `CLAUDE.md` 의 **하드룰 표** | 이 프로젝트에서 절대 하면 안 되는 것 + **누가 막나** | 규칙이 없는 것과 같다 |
| `CLAUDE.md` 의 스택·명령 | 실행·테스트 명령 | 에이전트가 매번 물어본다 |
| `docs/SPEC.md` | 요구 ID(`R-<영역>-<번호>`) | 추적표가 빈 채로 통과한다 |
| `docs/traceability.md` | SPEC 의 모든 요구에 한 행 | CI 의 `trace` 잡이 실패한다 |

> **하드룰마다 누가 막는지 반드시 적는다** — `git 훅` · `린터` · `테스트` · `CI` · `리뷰` · `사람`.
> **`사람` 만 적힌 규칙은 안 지켜진다고 가정하라.** 불편하면 자동으로 막게 바꾼다.

`docs/process/` 의 두 문서가 그 이유를 설명한다 — `artifact-rules.md`(R1~R7)와
`verification-layers.md`(어느 검사를 어디에 둘지, 실측 수치 포함).

## 3. 설치 **전에** 확인했어야 하는 것

**커밋 신원.** `install.sh` 는 설치 시점의 `git config user.email` 을 `.ai-kit/identity` 에
박고, 이후 훅이 그 값을 정답으로 검증한다. **틀린 값이 박히면 훅이 틀린 값을 지켜준다.**

```bash
git config user.email      # 이 레포에서 쓸 이메일이 맞는지 먼저 본다
```

다르면 `git config user.email '<쓸 이메일>'` 로 고치고 `.ai-kit/identity` 를 지운 뒤
`install.sh` 를 다시 돌린다.

## 4. 킷이 안 하는 것 — 기대하지 마라

- **커버리지·취약점 스캔은 프로젝트가 도구를 갖춰야 돈다.** Go 는 `go test -cover` 가
  내장이지만, Python 은 `pytest-cov`, Node 는 커버리지 provider, Kotlin 은 Kover 플러그인이
  프로젝트 의존성·빌드 스크립트에 있어야 한다. 취약점 스캔도 Python 은 락파일이나
  `requirements.txt` 가, Kotlin 은 OWASP Dependency-Check 플러그인이 있어야 한다.
  **킷이 대신 넣지 않는다** — 그러면 킷이 프로젝트의 의존성을 정하게 된다.
  없으면 CI 가 `::notice::` 로 무엇이 빠졌는지 말한다. 조용히 0 으로 지나가지 않는다.
- **Java** — `ktlint` 는 `.kt` 만 본다. Java 소스는 컴파일·테스트만 되고 **린트가 0**이다.
- **런타임 설치** — Go·JDK·Node·Python 은 프로젝트가 요구하는 버전이 있다. 킷은 안 깐다.
- **`pytest`·`mypy`** — 프로젝트 의존성이다. `uv.lock`·`poetry.lock`·`[dependency-groups]`·
  `[project.optional-dependencies]`·`requirements-dev.txt` 중 하나로 선언해야 CI 가 설치한다.
- **빌드 래퍼** — Gradle·Maven 은 `./gradlew`·`./mvnw` 를 **커밋해야** 한다. 없으면 CI 가 막는다
  (버전이 러너 이미지에 묶여 고정되지 않기 때문).
- **docker/compose** — 서비스 구성은 프로젝트마다 달라 템플릿을 주지 않는다.
- **e2e** — 무엇을 e2e 로 볼지는 프로젝트가 정한다.
- **낡음 감지는 로컬 전용** — 킷이 앞서 갔는지는 세션 시작 시 한 줄로 알린다. CI 는 모른다.

## 5. 킷이 바뀌면

```bash
<kit>/install.sh <이 레포 경로> --update --dry-run   # 무엇이 바뀔지만
<kit>/install.sh <이 레포 경로> --update             # 3-way 병합
```

`.ai-kit/gate/`·`git-hooks/` 는 킷 소유라 통째로 교체된다. `CLAUDE.md`·CI·린터 설정은
**프로젝트 소유**라 3-way 병합하고, 겹치면 충돌 마커를 남긴다 — 해소한 뒤 다시 돌려야
baseline 이 맞는다. **킷 파일로 덮지 마라**: 그 파일들엔 프로젝트 고유 설정이 들어 있다.

## 6. 킷 자체의 미결 항목

킷 레포의 GitHub 이슈에 있다. 킷이 무엇을 아직 못 하는지 알고 싶으면 거기를 본다.
