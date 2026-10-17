# ADR-0005: 시크릿 범위 스캔은 `git log --diff-merges=cc` 로 한다

- **상태**: 채택
- **날짜**: 2026-09-06 (PR #45)

## 맥락

`common/gate/secrets.sh` 의 범위 스캔(pre-push · CI)이 `git diff A..B` 였다. 두 끝점만
비교하므로 **넣었다가 다음 커밋에서 지운 시크릿이 안 보인다.** 그 시크릿은 히스토리에
남아 푸시된다.

`git log` 로 옮기면 그 커밋이 보이지만, `git log` 는 기본적으로 머지 커밋의 diff 를 내지
않아 **충돌을 손으로 풀며 써넣은 시크릿이 안 보인다.** 옮기며 실제로 확인한 표:

| 시나리오 | `git diff` | `git log` 기본 | `--diff-merges=cc` |
| --- | --- | --- | --- |
| 넣었다 다음 커밋에서 지움 | **못 찾아냄** | 찾아냄 | 찾아냄 |
| 충돌 해소 중에 손으로 써넣음 | 찾아냄 | **못 찾아냄** | 찾아냄 |
| 시크릿이 든 main 을 머지 | 찾아냄 | 찾아냄 | 찾아냄 |

**읽는 법.** `git diff` 가 못 찾아내는 것은 1행 하나다. 2행은 해소한 줄이 최종 트리에 남으므로
끝점 비교로도 찾아낸다 — 처음에 이 칸을 `—` 로 적었는데 실제로 확인하니 찾아냈다. 그래서 `git log` 로
옮기는 것만으로는 1행을 얻고 2행을 잃는다. `--diff-merges` 가 그것을 되돌려놓는다 —
`cc` 는 안 잃기 위해 필요한 것이지 덤이 아니다.

**3행은 어느 방식도 오탐으로 걸러내지 않는다.** 머지로 딸려 들어온 커밋이 범위 안에
있으면 그 내용도 검사 대상이다. `cc` 가 그 오탐을 없앤다고 적어둔 사본이 있었는데
(설치된 프로젝트 쪽) 재현해 보니 사실이 아니었다.

## 결정

파일 목록과 diff 를 `git log --diff-merges=cc` 로 얻는다. 결합 diff 는 부모 수만큼 열을
두므로 추가 줄은 `^[ +]*\+` 로 거른다 — `^\+` 로만 거르면 부모1 에만 있던 줄(` +`)을 놓치고,
머지가 부모1 쪽 시크릿을 남긴 경우가 그 모양이다. git 2.31+ 가 필요하다.

## 대안과 기각 사유

| 대안 | 기각 사유 |
| --- | --- |
| `git diff A..B` 그대로 | 넣었다 지운 시크릿을 찾아내지 못한다(1행) |
| `git log` 기본 | 충돌 해소 중에 써넣은 것을 찾아내지 못한다(2행) |
| `git log --first-parent` | 머지가 들여온 것 전부를 그 커밋 하나에 몰아 보고한다. 같은 내용을 원본 커밋에서 한 번, 머지에서 또 한 번 보고한다. 아래 재현 |

`cc` 와 `--first-parent` 가 출력하는 줄 수의 차이를 재현한다:

```bash
d=$(mktemp -d); cd "$d"; git init -q -b main
git config user.email a@b.c; git config user.name t
: > seed; git add -A; git commit -qm seed
git checkout -q -b feat; printf 'mine\n' > mine.txt; git add -A; git commit -qm mine
git checkout -q main
for i in $(seq 1 20); do seq 1 30 | sed "s/^/main-$i /" > "big$i.txt"; done
git add -A; git commit -qm "main: 20 files"
printf 'X\n' > shared.txt; git add -A; git commit -qm "main: shared=X"
git checkout -q feat; printf 'Y\n' > shared.txt; git add -A; git commit -qm "mine: shared=Y"
git merge -q --no-ff main >/dev/null 2>&1 || true
printf 'Z\n' > shared.txt; git add -A; git commit -qm "merge: resolved"
echo "cc           $(git show --diff-merges=cc --format= HEAD | wc -l)"
echo "first-parent $(git show --first-parent    --format= HEAD | wc -l)"
```

```
cc           8
first-parent 727
```

`cc` 는 모든 부모와 같은 hunk 를 생략하므로 머지 커밋에 남는 것이 해소 자리뿐이다.

## 결과

`secrets.sh` 의 범위 스캔 두 줄(파일 목록 · diff)이 이 결정이고, 그 옆 주석이 이 표를
요약한다. 이 설계는 처음에 설치된 프로젝트 쪽에서 나왔고 킷으로 가져왔다(PR #45).

되돌리려면 그 두 줄과 `^[ +]*\+` 정규식을 같이 건드려야 한다. 한쪽만 바꾸면 결합 diff 의
열이 안 맞는다.
