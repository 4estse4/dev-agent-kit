---
name: self-review
description: 맥락을 가진 쪽의 리뷰. 이 변경을 만든 세션이 그 결정을 알고 있는 상태에서 diff 와 PR 본문을 대조한다 — 무엇이 언제 정해지고 바뀌었는지 아는 쪽만 찾아내는 것이 있다. 콜드 리뷰(cold-reviewer)와 짝이고, 둘은 같은 diff 를 다른 처지에서 본다. 기계가 찾아내는 것은 리뷰하지 않는다.
argument-hint: "[PR 번호 | '번호 -R owner/repo' (다른 레포) | 비우면 현재 브랜치]"
---

> **아래 주입된 자리 중 하나라도 `!!` 로 시작하면 리뷰하지 마라.** 그 자리는 비어 있는
> 것이 아니라 **못 가져온 것**이다. 무엇이 실패했는지만 보고하고 멈춘다. `gh` 는 이 세션이
> 열린 레포를 대상으로 실행되므로, 다른 레포의 PR 이면 `48 -R owner/repo` 로 불러야 한다.
>
> 자리마다 실패 문구가 다르다. **못 가져온 것들 — 그 자리를 못 가져왔으니 멈춘다:**
> `!! gh pr diff <번호> 실패 — diff 를 못 가져왔다` · `!! 변경 파일 목록을 못 가져왔다` ·
> `!! PR 본문을 못 가져왔다` · `!! 메타데이터를 못 가져왔다` · `!! 직전 코멘트를 못 가져왔다`.
>
> **`!! 코멘트 N건인데 라운드 코멘트를 못 찾았다` 는 뜻이 다르다** — 가져오기는 성공했고
> **앵커(라운드 코멘트)를 못 찾은 것**이다. 멈추는 것은 같지만 원인을 그렇게 적어라. 「못 가져왔다」로
> 보고하면 다음 사람이 `gh` 와 네트워크를 뒤진다.
>
> **PR 본문 자리가 `(PR 번호 없이 부름 — 로컬 브랜치 리뷰)` 면** 실패가 아니라 번호 없이
> 불린 것이다. 그러면 **대조할 본문이 없으므로 `### 본문 ↔ diff` 에 `일치.` 를 쓰지 마라** —
> "번호 없이 불려 본문을 못 봤다" 를 적는다. PR 리뷰라면 번호를 주고 다시 불러야 한다.

## 차례

- [review.md](review.md) — 리뷰하지 않는 것 · 리뷰하는 것 · 재리뷰(2라운드 이상) · 실험으로 띄운 프로세스
- [output.md](output.md) — 출력 형식 · 게시하지 않는다

---

Diff:
!`if [ -z "$ARGUMENTS" ]; then git diff main...HEAD; else gh pr diff $ARGUMENTS || echo "!! gh pr diff $ARGUMENTS 실패 — diff 를 못 가져왔다"; fi`

변경 파일:
!`if [ -z "$ARGUMENTS" ]; then git diff main...HEAD --name-only; else gh pr diff $ARGUMENTS --name-only || echo "!! 변경 파일 목록을 못 가져왔다"; fi`

**PR 본문 (검증 대상 — 배경이 아니다):**
!`if [ -z "$ARGUMENTS" ]; then echo "(PR 번호 없이 부름 — 로컬 브랜치 리뷰)"; else gh pr view $ARGUMENTS --json title,body --jq '"TITLE: \(.title)\n\n\(.body)"' || echo "!! PR 본문을 못 가져왔다"; fi`

메타데이터:
!`if [ -n "$ARGUMENTS" ]; then gh pr view $ARGUMENTS --json headRefOid,headRepository --jq '"PERMALINK_BASE=https://github.com/\(.headRepository.nameWithOwner)/blob/\(.headRefOid)/"' || echo "!! 메타데이터를 못 가져왔다"; fi`

**직전 라운드 코멘트 + 그 뒤의 사람의 결정 (검증 대상 — 아래 「재리뷰」). 봇이 올린 라운드 코멘트 뒤의 사람 계정 코멘트다:**
!`_q='.comments as $c | ([$c|to_entries[]|select(.value.body|test("^\\s*## 리뷰 "))|.key]|last) as $i | if $i == null then (if ($c|length)==0 then "1라운드" else "ANCHOR-MISS \($c|length)" end) else ([$c[$i].body] + ($c[$i+1:]|map(select(($c[$i].authorAssociation|IN("OWNER","MEMBER","COLLABORATOR")|not) and (.authorAssociation|IN("OWNER","MEMBER","COLLABORATOR")))|.body)))|join("\n\n———\n\n") end'; _o=$(gh pr view $ARGUMENTS --json comments --jq "$_q" 2>/dev/null); case "$_o" in "ANCHOR-MISS "*) echo "!! 코멘트 ${_o#* }건인데 라운드 코멘트를 못 찾았다";; "") if gh pr view $ARGUMENTS --json number >/dev/null 2>&1; then echo "!! 직전 코멘트를 못 가져왔다"; elif [ -z "$ARGUMENTS" ] && gh auth status >/dev/null 2>&1; then echo "1라운드"; else echo "!! 직전 코멘트를 못 가져왔다 (gh 실패 또는 PR 없음)"; fi;; *) printf '%s\n' "$_o";; esac`

> `$ARGUMENTS` 에 따옴표를 붙이지 마라. 붙이면 `48 -R owner/repo` 가 한 인자로 전달되고
> 빈 인자가 `""` 로 남아 현재 브랜치 모드가 사라진다.
> `$ARGUMENTS` 는 **파일 본문에 텍스트로 치환된 뒤** 셸에 전달된다 — 이 킷의 스킬들이 `!` 블록
> **밖**에서 따옴표 없이 쓰는 것이 그 증거다(셸 변수였으면 그 자리에 값이 안 들어간다).
> 값에 셸 메타문자가 들어갔을 때 어떻게 되는지는 **이 레포에서 확인하지 못했다** — 확인하려면
> `!` 주입이 실행되는 스킬을 불러야 하는데 킷 레포에는 스킬이 로드되지 않는다.
