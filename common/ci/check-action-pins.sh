#!/usr/bin/env bash
# 킷 템플릿에 적힌 GitHub Action 버전이 뒤처졌는지 검사한다.
#
# 왜 이게 필요한가 — Dependabot 의 github-actions 생태계는 `.github/workflows/` 와
# 루트 `action.yml` 만 훑는다(공식 문서). 킷의 워크플로 원본은 `common/ci/gates.yml`
# 이라 **그 범위 밖이고, 영원히 갱신되지 않는다.** 그래서 새 프로젝트는 킷이 낡은 만큼
# 낡은 채로 시작한다. 이 검사가 그 자리를 대신 본다.
#
#   check-action-pins.sh [파일...]     기본값: 이 스크립트 옆의 gates.yml
#
# 뒤처진 핀이 있으면 종료코드 1.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=("$@"); [ ${#FILES[@]} -eq 0 ] && FILES=("$SELF_DIR/gates.yml")

command -v gh >/dev/null 2>&1 || { echo "check-action-pins: gh 가 필요합니다" >&2; exit 2; }

# 조회 실패를 통과로 처리하지 않는다 — 검사가 고장 나도 알리지 않고 통과하는 것이
# 이 킷이 반복해서 막아온 부류다.
behind=0; failed=0; checked=0
declare -a SEEN=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "check-action-pins: 파일 없음 — $f" >&2; exit 2; }
  while IFS= read -r pin; do
    # 하위 경로의 액션(actions/cache/restore@v6)은 그 레포의 태그를 따른다. 레포는 앞 두 마디다.
    # `owner/repo@` 만 읽으면 하위 경로의 액션을 말없이 건너뛴다.
    repo=$(printf '%s\n' "${pin%@*}" | cut -d/ -f1-2); cur=${pin#*@}
    case " ${SEEN[*]:-} " in *" $repo@$cur "*) continue ;; esac
    SEEN+=("$repo@$cur")
    case "$cur" in v[0-9]*) ;; *) continue ;; esac   # SHA 핀 등은 대상 아님
    latest=$(gh api "repos/$repo/tags" --paginate --jq '.[].name' 2>/dev/null \
             | grep -E '^v[0-9]+$' | sort -V | tail -1)
    if [ -z "$latest" ]; then
      echo "  ? $repo — 태그를 조회하지 못했습니다" >&2; failed=1; continue
    fi
    checked=$((checked+1))
    if [ "${cur%%.*}" != "$latest" ]; then
      echo "  ✗ $repo  $cur → $latest"; behind=1
    fi
  done < <(grep -ohE 'uses: +[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*@[A-Za-z0-9_.-]+' "$f" \
           | sed 's/uses: *//' | sort -u)
done

if [ "$failed" = 1 ]; then
  echo "check-action-pins — 조회 실패가 있어 판정할 수 없습니다" >&2; exit 2
fi
if [ "$behind" = 1 ]; then
  echo ""
  echo "위 핀이 뒤처졌습니다. 템플릿을 올리고 커밋하세요 —"
  echo "Dependabot 은 common/ci/ 를 보지 않으므로 아무도 대신 해주지 않습니다." >&2
  exit 1
fi
echo "check-action-pins ✓ ${checked}개 액션이 최신 major 입니다"
