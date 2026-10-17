#!/usr/bin/env bash
# 시크릿 스캔. 스테이지된 내용(기본) 또는 지정 ref 범위를 검사한다.
# 오탐을 줄이려 시크릿이 거의 확실한 패턴만 본다 — 엔트로피 추정은 하지 않는다.
# 정당한 테스트 픽스처는 같은 줄에 secret-ok 마커를 달아 면제한다.
#
#   secrets.sh              스테이지된 내용 검사 (pre-commit)
#   secrets.sh --range A..B 커밋 범위 검사 (pre-push / CI)
#   secrets.sh --range REV   리비전 하나 — 거기서 도달 가능한 **모든** 커밋을 검사한다.
#                            기준점이 없을 때 쓴다(고아 브랜치, 기본 브랜치의 첫 푸시).
#                            A..B 는 A 를 제외하므로 그 경우 루트 커밋이 빠진다.
set -uo pipefail

MODE="staged"; RANGE=""
[ "${1:-}" = "--range" ] && { MODE="range"; RANGE="${2:-}"; }

# ── 1. 파일명으로 금지 ──────────────────────────────────────────
FORBIDDEN_NAMES='(^|/)(\.env(\..*)?|.*-key\.json|.*\.pem|.*\.p12|.*\.pfx|id_rsa|id_ed25519|credentials\.json|service-account.*\.json)$'
ALLOWED_NAMES='(\.env\.example|\.env\.sample|\.env\.template)$'

# git 실패를 무시하면 DIFF 가 비어 "매치 없음 = 통과" 가 된다.
# 범위 해석 실패(shallow clone·사라진 SHA·잘못된 인자)는 검사 불능이지 통과가 아니다.
#
# core.quotePath 기본값(true)은 비ASCII 경로를 8진수로 이스케이프해 따옴표째 내보낸다.
# 그 문자열은 끝이 `"` 라 FORBIDDEN_NAMES 의 `$` 에 안 맞고, 한글 디렉터리 아래의
# .env 나 키 파일이 이름 검사를 그대로 통과한다(실제로 확인함). 두 모드 다 같은 자리다.
if [ "$MODE" = staged ]; then
  FILES=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM) || {
    echo "시크릿 스캔 오류: 스테이지된 목록을 읽지 못했습니다." >&2; exit 2; }
else
  # `git diff A..B` 는 두 끝점만 비교한다 — 넣었다 지운 시크릿이 안 보이는데,
  # 지우는 것이 사람이 하는 가장 흔한 복구 동작이다. 그래서 커밋 단위로 훑는다.
  #
  # --diff-merges=cc 인 이유:
  #  · `git log` 는 기본적으로 머지 커밋의 diff 를 내지 않는다. 충돌을 손으로 풀며
  #    써넣은 줄은 어느 부모에도 없어 **어느 커밋에도 안 나타난다.** 실제로 확인한 결과: 그 시나리오에서
  #    기본은 시크릿 추가 줄 0개, `cc` 는 1개.
  #  · `cc`(dense combined diff)는 모든 부모와 같은 hunk 를 생략한다. 그래서 머지
  #    커밋이 내놓는 것이 정확히 해소 자리다. 실제로 확인한 결과(main 이 큰 변경을 들여온 머지):
  #    머지 커밋 하나의 diff 가 `cc` 8줄 · `--first-parent` 727줄. 같은 내용을 원본
  #    커밋에서 한 번, 머지에서 또 한 번 보고하지 않는다.
  #  · git 2.31+ 가 필요하다 — `--diff-merges` 자체가 그때 들어왔다.
  #
  # **이것이 하지 않는 일**: 범위에 머지로 딸려 들어온 커밋이 있으면 그 커밋의 내용도
  # 검사한다. 시크릿이 든 main 을 머지한 브랜치는 `cc` 든 `--first-parent` 든 `git diff`
  # 든 똑같이 막힌다 — 실제로 확인하니 셋 다 같은 파일을 짚었다. `cc` 가 그 오탐을 없앤다고
  # 적어둔 판이 있는데 그건 사실이 아니다.
  FILES=$(git -c core.quotePath=false log --name-only --diff-filter=ACM --diff-merges=cc --pretty=format: "$RANGE" | sort -u | sed '/^$/d') || {
    echo "시크릿 스캔 오류: 범위 '$RANGE' 를 해석하지 못했습니다 — 검사를 신뢰할 수 없어 중단합니다." >&2
    exit 2; }
fi

BAD_NAMES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s' "$f" | grep -qE "$ALLOWED_NAMES" && continue
  printf '%s' "$f" | grep -qE "$FORBIDDEN_NAMES" && BAD_NAMES="${BAD_NAMES}  ${f}"$'\n'
done <<< "$FILES"

# ── 2. 내용으로 금지 ────────────────────────────────────────────
# 패턴을 변수로 조립해 이 스크립트 자신이 스캔 결과에 나오지 않게 한다.
P_PRIVKEY='-----BEGIN [A-Z ]*PRIVATE KEY-----'
P_JSONKEY='"'"private_key"'"[[:space:]]*:[[:space:]]*"'
P_AWS='AKIA[0-9A-Z]{16}'
P_GH='gh[pousr]_[A-Za-z0-9]{30,}'
P_SLACK='xox[baprs]-[A-Za-z0-9-]{10,}'
P_GCP='AIza[0-9A-Za-z_-]{35}'
P_OPENAI='sk-[A-Za-z0-9_-]{20,}'
PATTERNS="${P_PRIVKEY}|${P_JSONKEY}|${P_AWS}|${P_GH}|${P_SLACK}|${P_GCP}|${P_OPENAI}"

if [ "$MODE" = staged ]; then
  DIFF=$(git diff --cached -U0) || {
    echo "시크릿 스캔 오류: 스테이지된 diff 를 읽지 못했습니다." >&2; exit 2; }
else
  DIFF=$(git log -p -U0 --diff-merges=cc --pretty=format: "$RANGE") || {
    echo "시크릿 스캔 오류: 범위 '$RANGE' diff 를 읽지 못했습니다." >&2; exit 2; }
fi

# 추가된 줄(+)만 본다. secret-ok 마커가 있으면 면제.
#
# 앞에 `[ +]*` 가 붙는 이유: `--diff-merges=cc` 의 결합 diff 는 부모 수만큼 열을 둔다.
# 두 부모면 `++` 는 어느 부모에도 없는 줄, ` +`(공백 뒤 +)는 부모1 에는 있고 부모2 에는
# 없는 줄이다. `^\+` 만 보면 뒤엣것을 통째로 놓친다 — 머지가 부모1 쪽을 골라 남긴
# 시크릿이 그 모양이다(실제로 확인함). -U0 이라 문맥 줄이 없으므로 이 패턴이 문맥 줄에 맞을 일이 없다.
#
# grep 종료코드: 0=매치, 1=매치없음(정상), >=2=grep 자체 오류.
# 오류를 || true 로 무시하면 검사가 고장 난 채 "통과"한다 — 반드시 구분한다.
ADDED=$(printf '%s\n' "$DIFF" | grep -E -- '^[ +]*\+' | grep -vE -- 'secret-ok')
BAD_CONTENT=$(printf '%s\n' "$ADDED" | grep -nE -- "$PATTERNS")
rc=$?
if [ $rc -ge 2 ]; then
  echo "시크릿 스캔 오류: grep 실패 (exit $rc) — 검사를 신뢰할 수 없어 중단합니다." >&2
  exit 2
fi

if [ -z "$BAD_NAMES" ] && [ -z "$BAD_CONTENT" ]; then
  exit 0
fi

echo "" >&2
if [ "$MODE" = staged ]; then
  echo "시크릿 스캔 실패 — 커밋을 중단합니다." >&2
else
  echo "시크릿 스캔 실패 — 이 범위의 커밋 중 하나가 시크릿을 들여왔습니다." >&2
fi
[ -n "$BAD_NAMES" ] && { echo "" >&2; echo "금지된 파일:" >&2; printf '%s' "$BAD_NAMES" >&2; }
if [ -n "$BAD_CONTENT" ]; then
  echo "" >&2; echo "시크릿 패턴이 포함된 추가 줄:" >&2
  printf '%s\n' "$BAD_CONTENT" | sed 's/^/  /' >&2
fi
# 조치 안내는 모드마다 다르다. range 는 **이미 커밋된 것**이라 "스테이지에서 빼라" 가
# 통하지 않는다 — 그 안내를 그대로 내면 사람이 시키는 대로 하고도 계속 막히고,
# 진짜 시크릿이었을 때 폐기가 그만큼 늦어진다.
if [ "$MODE" = staged ]; then
  cat >&2 <<'MSG'

조치:
  · 실제 시크릿이면 파일을 스테이지에서 빼고 .gitignore에 넣는다.
  · 테스트용 더미면 같은 줄 끝에 secret-ok 주석을 단다.
MSG
else
  cat >&2 <<'MSG'

조치 — 이미 커밋된 것이라 **지금 지우는 것으로는 해소되지 않습니다.**
  · 실제 시크릿이면: 먼저 그 키를 폐기·재발급하세요. 되돌릴 수 없습니다.
    그 뒤 히스토리에서 지웁니다 — git rebase -i 로 해당 커밋을 고치거나,
    브랜치를 다시 만들어 깨끗한 커밋으로 옮깁니다.
  · 테스트용 더미면: 그 줄 끝에 secret-ok 주석을 달되, **그 커밋 자체를 고쳐야**
    합니다. 뒤 커밋에서 주석만 추가하면 범위 스캔은 계속 실패합니다.
MSG
fi
exit 1
