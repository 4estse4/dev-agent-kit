## 4. base 복귀와 브랜치 삭제

`<baseRefName>` · `<headRefName>` · `isCrossRepository` 는 2절이 받아 둔 값이다. **이름을 여기서 새로 구하지 마라.**
이 절은 base 로 옮긴 **뒤**에 브랜치를 지우고, `$ARGUMENTS` 로 **다른 PR 을 번호로 머지하는
것이 정상 경로**라서(`argument-hint`), 지금 체크아웃의 브랜치가 그 PR 의 브랜치가 아닐 수 있다.

**base 로 돌아온다:**

    if [ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ] && git switch <baseRefName>; then git pull --ff-only; else git fetch origin && git switch --detach origin/<baseRefName> && { git fetch -q origin <baseRefName>:<baseRefName> 2>/dev/null || true; }; fi

원래 체크아웃에서(`--absolute-git-dir` 와 `--git-common-dir` 가 같다) `git switch` 가 되면 base 브랜치에서
fast-forward 한다. fast-forward 실패 시 중단: `Error: <baseRefName> 을 fast-forward 할 수 없습니다.`
**절대 경로 형태로 견준다.** 원래 체크아웃의 하위 디렉터리에서 `--git-dir` 는 절대 경로를, `--git-common-dir` 는
`../../.git` 같은 상대 경로를 출력해서, 그대로 견주면 원래 체크아웃을 worktree 로 판정한다. 세션의 작업
디렉터리는 호출 사이에 유지되므로 하위 디렉터리에서 실행되는 일이 흔하다.

**git worktree 에서는 base 로 옮기지 않는다. fetch 한 뒤 `origin/<baseRefName>` 에 detach 한다.** worktree 가
base 브랜치에 있으면 원래 체크아웃이 base 로 옮기지 못한다. 원래 체크아웃이 다른 브랜치에 있으면 worktree 의
`git switch` 는 성공하므로, 되는지를 보지 않고 worktree 인지로 구분한다. 원래 체크아웃에서도 다른
worktree 가 base 를 쓰면 `git switch` 가 `fatal: '<baseRefName>' is already used by worktree at …` 로 실패하고,
그때도 detach 한다. PR 브랜치에서 내려와야 아래에서 그 브랜치를 지울 수 있다.

**detach 한 뒤 로컬 base 브랜치도 fast-forward 한다(`git fetch origin <baseRefName>:<baseRefName>`).** 로컬 base 가
머지 전 커밋에 머물면, 그 뒤 만든 브랜치에서 `open-pr` · `dev-log` · `trace` 가 주입하는 `git log main..HEAD` 가 방금
머지한 커밋을 그 브랜치의 변경으로 보여 준다. base 를 쓰는 체크아웃이 있으면 git 이
`refusing to fetch into branch … checked out at …` 로 거부하고, 그 체크아웃은 그곳의 사람이 직접 pull 한다.
그래서 이 갱신의 실패는 줄의 종료 코드에 섞지 않는다(`|| true`). **이 거부는 git 2.35 부터다.** 그 전 git 은
현재 worktree 의 브랜치만 보호해서, 원래 체크아웃이 쓰는 base 의 ref 만 옮기고 그 작업 트리는 머지 전으로
둔다. 킷이 전제하는 macOS · ubuntu CI 의 git 은 그보다 새것이다.

**이 줄의 종료 코드가 0 이 아니면 중단한다.** fetch 가 네트워크 때문에 실패하면 그 줄이 실패한다.
fetch 를 따로 두면 fetch 가 실패해도 멈추지 않고 받아 둔 옛 `origin/<baseRefName>` 에 detach 해서, 머지 전
커밋에 있는 채 브랜치를 지우고 5절이 그 SHA 를 보고한다. base 로 옮기는 경로는 `git pull --ff-only` 가
fetch 한다.

**이 줄은 설치된 레포에서 어느 분기가 실행되든 권한 프롬프트를 거친다.** Claude Code 는 `;` · `&&` 로 나뉜
조각마다 따로 규칙에 맞는지 보고(권한 문서의 Compound commands: "A rule must match each subcommand
independently."), `git fetch` 는 설치되는 `settings.json` 의 `allow` 에 없다. 어느 분기가 실행될지는
실행 전에 모른다. 사람이 거절하면 줄 전체가 실행되지 않는다. 그때도 중단하고, 5절의 보고에 머지는
끝났고 base 복귀와 브랜치 삭제는 하지 않았다고 적는다. 다시 부른 스킬의 2절이 `MERGED` 를 보고 이 절을
다시 실행하므로, 사람이 거절한 명령이 다시 권한 프롬프트로 나온다.

**원격 브랜치를 지운다. `isCrossRepository` 가 `true` 면 지우지 않는다:**

    git push origin --delete <headRefName>

fork 에서 온 PR 의 head 브랜치는 fork 에 있다. origin 에 같은 이름의 브랜치가 있으면 그것은 base
레포의 다른 브랜치다. gh 도 이 경우 원격 삭제를 건너뛰었다(v2.92.0 `deleteRemoteBranch` 의
`crossRepoPR`). 그때는 명령을 실행하지 않고 5절에 「fork PR 이라 원격 브랜치를 지우지 않았다」고 적는다.

`remote ref does not exist` 로 실패하면 이미 지워진 것이다. 레포가 머지 뒤 원격 브랜치를
자동으로 지우는 설정이면 그렇다. 그 밖의 실패는 5절의 보고에 한 줄 덧붙인다. 이 명령은
`settings.json` 의 `ask` 에 있어 권한 프롬프트를 거친다. 승인은 3절에서 명령을 보이고 받았다.
사람이 이 프롬프트에서 거절하면 원격 브랜치를 남긴 채 아래 로컬 삭제를 진행하고, 5절에 남겼다고 한
줄 덧붙인다.

**로컬 브랜치가 남아 있으면 지운다.** 2절이 로컬과 서버가 같다는 것을 머지 전에 확인했으므로
지워도 잃을 것이 없다:

    git rev-parse --verify --quiet <headRefName>   # 출력이 없으면 로컬에 없다. 5절을 진행한다
    git branch -D <headRefName>                    # 출력이 있으면 지운다

`cannot delete branch '<headRefName>' used by worktree at <경로>` 로 실패하면 다른 worktree 가
그 브랜치를 쓰고 있다. 원래 체크아웃에서 번호로 머지했고 PR 브랜치는 worktree 의 세션이 쓰는
경우다. 지우지 말고 남긴 채, 5절의 보고에 그 경로와 함께 남겼다고 한 줄 덧붙인다.

**`-d` 가 아니라 `-D` 인 이유.** 원격 추적 ref 가 지워진(prune) 레포에서는 `-d` 가 다 푸시한
브랜치도 거부한다. 2절이 이미 확인한 것을 다시 확인하느라 멀쩡한 삭제를 막을 까닭이 없다.

**`-D` 에서 권한 프롬프트가 표시된다**(`settings.json` 의 `ask`). 사람이 거절하면 브랜치를 남기고,
5절의 보고에 남겼다고 한 줄 덧붙인다.

**`--verify --quiet` 를 빼지 마라.** 옵션 없이 실행한 `git rev-parse <없는 브랜치>` 는 `rc=128` 로 실패하면서
**인자를 stdout 으로 그대로 출력한다**(`fatal:` 은 stderr 로 출력된다). 읽는 쪽이 그것을 SHA 자리에서
받으면, 이미 지워진 **정상 경로에서 이 절이 멈춘다.** 실제로 확인한 결과:

    $ git rev-parse nosuchbranch                    → stdout `nosuchbranch`, rc=128
    $ git rev-parse --verify --quiet nosuchbranch   → 출력 없음, rc=1

**머지 뒤에야 나오는 것.** 머지해야 비로소 확인되는 것이 있다(4절의 삭제가 실제로 됐는지
처럼). **결정 코멘트는 머지 전에 올린 기록이므로 그 결과를 결정 코멘트에 넣지 마라.** 3절의
「같은 코멘트를 다시 올리지 마라 — 그 뒤에 코멘트로」와 같은 방식으로 **결정 코멘트 뒤에
코멘트를 하나 더 붙인다.** 결정 코멘트를 편집으로 채우면 한 번 올린 기록이 바뀌고, 편집한
뒤에 생긴 것은 또 빠진다. 실제로 둘 다 있었다 — 결정 코멘트의 빈 칸을 머지 뒤 편집으로
채웠고, 그 편집 뒤에 연 이슈가 최종 기록에서 빠졌다. **이 후속 코멘트도 응답에 초안 전문을 출력하고
승인받은 뒤 올린다.** `docs/process/verification-stages.md` 6.3 의 표가 이 코멘트의 승인을 「지금은 받는다」로 정했다.

## 5. 한 줄 보고
`Merged PR #<N>. main at <short SHA>. dev-log: 있음|없음|판정 못 함.`

auto-merge 를 켜고 끝낸 응답(3절 「봇 설정이 있을 때」)에서는 머지 전이라 이렇게 적는다:
`Auto-merge on PR #<N> at <short head SHA>. dev-log: 있음|없음|판정 못 함.` 머지 뒤 정리에서 위 줄을 적는다.

`없음` 과 `판정 못 함` 은 2절에서 사람이 알고도 머지를 지시한 경우뿐이고, 그 사실은 결정 코멘트에
적혀 있다. 판정 못 한 것을 `없음` 으로 적지 않는다 — 그것이 2절의 그 확인이 없애려는 거짓 기록이다.

이후 새 작업을 스스로 시작하지 않고 2절의 「다음 일」 창으로 묻는다. 다음 작업을 시작할 때의 정리로 불렀으면(`SKILL.md` 「꼭 지킬 것」의 예외) 사람이 시킨 그 작업으로
돌아간다. 머지된 PR 이 더 있으면 그 PR 도 정리한 뒤다.
