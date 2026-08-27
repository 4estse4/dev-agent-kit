# .ai-kit — 이 레포에 vendor 된 게이트

이 디렉터리는 [ai-native-kit](https://github.com/4estse4/ai-native-kit) 의 게이트를
복사해 둔 것이다. **레포와 함께 버전 관리되므로 clone 하면 따라온다.**

## 새로 clone 했다면 — 한 줄이 필요하다

```bash
git config core.hooksPath .ai-kit/git-hooks
```

훅 *파일* 은 clone 을 따라오지만, 그것을 활성화하는 `core.hooksPath` 설정은
따라오지 않는다 — git 이 보안상 의도한 동작이고 우회 방법이 없다.

활성화하면 다음이 걸린다:

| 시점 | 막는 것 |
| --- | --- |
| `pre-commit` | 보호 브랜치 직접 커밋 · 시크릿 · 커밋 신원 불일치 |
| `pre-push` | 변경 영역의 포맷·린트·타입·테스트 실패 · 시크릿 |

## 로컬 훅은 강제가 아니다

`git commit --no-verify` 로 넘어가고, 위 설정을 안 한 clone 에서는 아예 돌지 않는다.
**우회 불가능한 강제는 CI + 브랜치 보호뿐이다.** 로컬 훅은 CI 를 기다리지 않고
빨리 알려주는 용도다.

## 직접 실행

```bash
bash .ai-kit/gate/gate.sh          # 변경 영역만
bash .ai-kit/gate/gate.sh --all    # 전체 (CI 와 동일, 도구 부재를 실패로 처리)
bash .ai-kit/gate/trace.sh         # SPEC ↔ 추적 매트릭스 정합
bash .ai-kit/gate/secrets.sh       # staged 시크릿 스캔
```

## 손으로 고치지 마라

`install-manifest` 에 내용 체크섬이 있고 CI 가 재계산한다. 게이트를 바꿔야 하면 킷 레포에서
고치고 `install.sh` 를 다시 실행한다 — 그래야 다른 프로젝트에도 반영되고,
버전 표시가 실제 내용과 어긋나지 않는다.
