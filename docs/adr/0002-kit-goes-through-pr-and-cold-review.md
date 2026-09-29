# ADR-0002: 킷 자신도 브랜치 → PR → 콜드 리뷰 → 머지 순서를 따른다

- **상태**: 채택
- **날짜**: 2026-08-24 (PR #1). 2026-09-12 에 `main` 룰셋으로 강제됐다 — 아래 「결과」

## 맥락

킷은 프로젝트에 「`main` 직접 커밋 금지 · 설정·CI·훅·게이트 스크립트는 글이 아니라
코드다 · 콜드 리뷰는 기본으로 실행한다」를 적어 주었지만, 자기 레포에서는 바로 그 파일들을
고치면서도 그 규칙을 한 번도 따르지 않았다.

**리뷰 없이 8커밋을 푸시했더니 기능이 작동하지 않았다.** 2026-08-24 세션에서 킷 `main` 에
PR 없이 · 콜드 리뷰 없이 8커밋을 넣었고, 뒤늦게 콜드 리뷰를 실행하자 9건이 나왔다. 가장
나쁜 것은 `gate_go_tool` 함수가 통째로 사라진 것이었다 — 다른 함수를 줄 범위로
잘라 바꾸면서 같은 구간의 무관한 함수를 같이 지웠고 호출부만 남았다. `GATE_STRICT` 기본값을
1 로 바꾼 직후라 **모든 Go 프로젝트가 커밋·푸시·CI 에서 실패**하는 상태로 `main` 에 푸시돼 있었고,
메시지는 이미 설치된 도구를 설치하라고 했다.

| | 찾은 것 |
| --- | --- |
| 작성자 자신(우연히 다시 봄) | 4건 — 전부 "덜 좋은 것" |
| 콜드 리뷰 | **9건** — 상당수가 "기능이 작동하지 않음" |

같은 세션에서 커밋 린트가 엉뚱한 파일을 검사하고 있었던 것(범위가 `main...HEAD` 라
브랜치 두 번째 커밋부터 스테이지한 파일이 범위 밖), 충돌 마커 검사가 한글 파일명에서
마커를 찾지 못하고 통과하던 것(`core.quotePath` 기본값)도 콜드 리뷰가 찾아냈다.

**두 리뷰는 서로 다른 것을 찾아낸다.** 실제 프로젝트의 PR 둘에서 확인한 값이다(2026-08-21):

| | 1차 PR | 2차 PR |
| --- | --- | --- |
| 셀프(맥락 보유) | 3건 | 3건 |
| 콜드(맥락 없음) | **11건** | **7건** |

콜드가 크게 앞섰지만 **셀프만 찾아낸 것도 있다** — "PR 본문이 5개 커밋만큼 낡았다"는
맥락을 가진 쪽만 안다.

## 결정

킷 자신도 **브랜치 → PR → 콜드 리뷰 → 머지** 순서를 따른다. PR #1 부터다. 두 리뷰(셀프 ·
콜드)를 다 실행하고, 한 리뷰로 줄이지 않는다.

게이트 · 훅 · 권한 규칙을 킷 자신에게 적용하는 것은 이 결정과 별개로 두었다. 그것은 열린
결정으로 이슈 #4 에 있고, 이 레포에서는 킷의 스킬 · 훅 · `settings.json` 이 로드되지
않는다.

## 대안과 기각 사유

| 대안 | 기각 사유 |
| --- | --- |
| `main` 직접 커밋 + 작성자가 다시 본다 | 위 표. 작성자가 찾은 4건은 전부 "덜 좋은 것"이었고, 콜드가 찾은 9건은 상당수가 "기능이 작동하지 않음"이었다 |
| 리뷰 하나만 실행한다 | 콜드가 앞서지만 셀프만 찾아낸 것이 있다. 서로 다른 것을 찾아낸다 |
| 게이트 · 훅 · 권한 규칙까지 킷 자신에게 적용한다 | 이 레포에서는 그 계층들이 로드되지 않고, 그렇게 하려면 심링크 · 훅 경로 · `settings.json` 두 벌 문제를 각각 풀어야 한다(이슈 #4). PR 흐름과 분리해서 정한다 |

## 결과

킷 `CLAUDE.md` 하드룰의 첫 줄이 이것이다. 「누가 막나」는 처음에 `사람`(지금의 `막는 것 없음`) 뿐이었다.

**2026-09-12 에 사람이 `main` 에 룰셋을 켰다.** enforcement 는 active 이고, bypass 목록은
비어 있어 레포 주인에게도 적용된다. 대상은 기본 브랜치, 머지 방법은 스쿼시만, 승인 수는
0, required check 는 `tests` 하나이고, up to date 요구는 꺼져 있다. 이 ADR 을 쓰며 다시 확인한 값:

```
$ gh api repos/4estse4/ai-native-kit/rules/branches/main --jq '[.[].type]'
["deletion","non_fast_forward","pull_request","required_status_checks","required_linear_history"]

$ gh api repos/4estse4/ai-native-kit/rulesets --jq '.[] | {name, enforcement, target}'
{"enforcement":"active","name":"main","target":"branch"}
```

**2026-09-28 11:42 KST 에 사람이 룰셋에 승인 조건 셋을 더했다.** 세션이 GitHub App 의 봇 계정으로 PR 을
열게 되어(이슈 #53) 사람이 그 PR 을 Approve 할 수 있게 된 뒤다. 필요 승인 1 · 새 커밋이 오면 이전 승인
무효 · 마지막 푸시는 푸시한 사람이 아닌 사람이 승인해야 한다. 그날 다시 확인한 값:

```
$ gh api repos/4estse4/ai-native-kit/rules/branches/main --jq '.[] | select(.type=="pull_request") | .parameters | {required_approving_review_count, dismiss_stale_reviews_on_push, require_last_push_approval}'
{"dismiss_stale_reviews_on_push":true,"require_last_push_approval":true,"required_approving_review_count":1}
```

룰셋이 막는 것은 PR 없는 push · `tests` 가 빨간 채로 머지 · 스쿼시 아닌 머지 · 사람의 Approve 없는 머지 ·
`main` 삭제까지다. **콜드 리뷰를 실행했는지는 룰셋이 안 본다.** 그것은 여전히 `사람`(지금의 `막는 것 없음`) 이다.

룰셋 때문에 낡은 자리가 있고, 그 자리는 이슈 #4 에 적었다. `.github/workflows/kit-tests.yml`
머리는 「이것은 required check 가 아니다」라고 적었다(2026-09-29 PR #166 에서 고침). `merge-pr` 2절에는 보호를 확인하는
명령이 없고 「브랜치 보호가 없는 레포라면 그 사실을 먼저 알린다」 한 줄만 있는데, 그 줄이
가리키는 `install.sh --protect` 는 클래식 보호를 설정한다(`gh api -X PUT`). 사람이 켠 것은
룰셋이라 클래식 엔드포인트로 보면 404 이고, 룰셋은
`repos/{owner}/{repo}/rules/branches/{branch}` 가 보여 준다. 확인 명령을 스킬에 넣을지와
`--protect` 를 룰셋으로 바꿀지는 이슈 #4 에서 정한다. 룰셋의
`require_extra_approval_for_unattributed_changes` 가 `true` 라 머지가 막히면 그것부터 본다.

되돌리려면 룰셋과, `CLAUDE.md` 하드룰 표에서 룰셋을 적은 줄(첫 줄과 「킷 히스토리를
재작성하지 마라」 줄)을 같이 건드려야 한다. 룰셋만 끄면 규칙은 남고 강제만 사라진다.
