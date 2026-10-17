# .kit — 이 레포에 복사해 둔 게이트

이 디렉터리는 [dev-agent-kit](https://github.com/4estse4/dev-agent-kit) 의 게이트를
복사해 둔 것이다. **레포와 함께 버전 관리되므로 clone 하면 따라온다.**

## 새로 clone 했다면 — 한 줄이 필요하다

```bash
git config core.hooksPath .kit/git-hooks
```

훅 *파일* 은 clone 을 따라오지만, 그것을 활성화하는 `core.hooksPath` 설정은
따라오지 않는다 — git 이 보안상 의도한 동작이고 우회 방법이 없다. 킷의 Claude Code 설정(`.claude/`)도 설치한
레포에서는 세션이 시작할 때 훅이 꺼졌다는 알림을 받고, 켜기 전에는 에이전트 훅이 세션의 `git commit` ·
`git push` 를 막는다. `.claude/` 를 설치하지 않은 레포와 세션 없이 터미널에서 커밋하는 사람에게는 이 안내뿐이다.

활성화하면 다음을 막는다:

| 시점 | 막는 것 |
| --- | --- |
| `pre-commit` | 보호 브랜치 직접 커밋 · 커밋 신원 불일치 · 충돌 마커 · 커밋에 안 들어간 `gate.conf`(아래) · 시크릿 · 스테이지한 파일이 있는 모듈의 포맷·린트·타입(테스트·빌드는 뺀다. JVM 은 ktlint 만) |
| `pre-push` | 커밋하지 않은 `gate.conf` · 변경 영역의 포맷·린트·타입·테스트·빌드 실패 · 시크릿 · 요구 추적 |

## 로컬 훅은 실수만 막는다

`git commit --no-verify` 로 우회되고, 위 설정을 안 한 clone 에서는 아예 실행되지 않는다.
**일부러 하는 우회까지 막는 것은 CI + 브랜치 보호뿐이다.** 다만 시크릿처럼 푸시되면 되돌릴 수
없는 것을 킷이 푸시 전에 막는 자리는 로컬 훅뿐이다.

## 직접 실행

```bash
bash .kit/gate/gate.sh          # 변경 영역만
bash .kit/gate/gate.sh --all    # 전체 (CI 와 동일)
bash .kit/gate/trace.sh         # SPEC ↔ 추적 매트릭스 정합
bash .kit/gate/secrets.sh       # staged 시크릿 스캔
```

위 `gate.sh` 두 명령 모두 도구가 없는 검사를 실패로 처리한다. 불가피하게 건너뛰려면
`KIT_ALLOW_MISSING_TOOLS=1` 을 붙인다. 그러면 그 검사는 실행되지 않고, 그 검사 때문에
게이트가 실패하지도 않는다. 건너뛴 검사는 `gate — 건너뜀(도구 없음):` 줄에 출력된다.
Claude Code 세션 안(`CLAUDE_CODE_CHILD_SESSION=1`)에서는 이 변수도 `GATE_STRICT=0` 도 받지 않는다 — 도구를 설치하거나,
사람이 세션 밖 터미널에서 실행한다.

## 게이트 설정 — `.kit/gate.conf`

프로젝트가 정하는 게이트 설정은 이 디렉터리의 `gate.conf` 에 `키=값` 한 줄씩 적고 커밋한다. 없으면 기본값이다. 환경 변수로는
받지 않는다 — 명령 앞에 붙인 값은 커밋에도 리뷰에도 남지 않는데 검사를 줄인다. 이 파일에 커밋에 안 들어간 변경이 있으면
커밋 훅과 푸시 훅이 실패한다. 이 파일은 프로젝트 소유라 킷을 다시 설치해도 남는다.

```
# 공유 DB 를 쓰는 통합 테스트를 직렬로 실행한다
KIT_GO_TEST_FLAGS=-p 1
KIT_PYTEST_FLAGS=-x
KIT_GRADLE_TASKS=check
KIT_PRUNE_DIRS=.git node_modules .venv .tox __pycache__
```

- `KIT_GO_TEST_FLAGS` · `KIT_PYTEST_FLAGS` — `go test` · `pytest` 에 더할 플래그. `KIT_GRADLE_TASKS` — `check` 대신
  실행할 gradle 태스크. `KIT_PRUNE_DIRS` — 모듈을 찾을 때 건너뛸 디렉터리 이름. 경로가 아니라 이름이라 어느 깊이에서든
  그 이름의 디렉터리를 모두 건너뛰고, `apps/legacy` 같은 경로는 어느 디렉터리에도 맞지 않는다. 기본 목록(위 예의 값)을
  통째로 바꾼다.
- `#` 로 시작하는 줄은 읽지 않는다. 값은 `=` 뒤 줄 끝까지이고 셸로 풀지 않는다 — 줄 끝에 붙인 `#` 주석과 따옴표도 값에
  들어간다. 값은 공백에서만 나뉘어 명령의 인자가 된다. 같은 키가 여럿이면 마지막 줄을 쓴다. 값이 비거나 공백뿐이면
  기본값이다.
- 모듈을 찾다가 읽지 못한 디렉터리(권한이 없는 것)가 있으면 게이트는 실패하지 않고 그 디렉터리를 출력에 알린다. 그 안의
  모듈은 검사되지 않았다.

## `drafts/` — 세션의 PR 본문 · 코멘트 조각

Claude Code 세션이 PR 본문과 코멘트의 조각을 두는 자리다(`.claude/skills/open-pr/drafts.sh` 가 처음 불릴 때 만든다).
그 안의 `.gitignore` 가 디렉터리 전체를 무시해 커밋되지 않고, `install.sh` 를 다시 실행해도 지우지 않는다.

## 고쳐도 된다. 대신 고친 것을 킷에도 올려라

급하면 여기서 바로 고쳐라 — 게이트가 틀렸는데 고치지 못하게 막는 것이 더 나쁘다.
검사는 없다. `install-manifest` 는 **어느 킷에서 왔는지**만 적고 내용은 검사하지 않는다.

다만 두 가지를 알고 고쳐라.

1. **`install.sh` 를 다시 실행하면 사라진다.** `.kit/gate`·`git-hooks` 는 킷 소유라
   통째로 교체된다. 무엇이 달라졌는지는 다시 설치하기 전에 `--dry-run` 으로 본다.
2. **킷에 올리지 않으면 다음 프로젝트가 같은 버그를 다시 겪는다.** 실제로 그랬다 —
   한 프로젝트와 킷이 같은 결함을 따로 고쳐 같은 코드가 두 번 나왔다.
