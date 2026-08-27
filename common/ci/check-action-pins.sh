#!/usr/bin/env bash
# 킷 템플릿에 박힌 버전이 뒤처졌는지 검사한다 — GitHub Action 과 게이트 도구 둘 다.
#
# 왜 이게 필요한가 — Dependabot 의 github-actions 생태계는 `.github/workflows/` 와
# 루트 `action.yml` 만 훑는다(공식 문서). 킷의 워크플로 원본은 `common/ci/gates.yml`
# 이라 **그 범위 밖이고, 영원히 갱신되지 않는다.** 그래서 새 프로젝트는 킷이 낡은 만큼
# 낡은 채로 시작한다. 이 검사가 그 자리를 대신 본다.
#
# 게이트 도구(`common/gate/tool-versions`)도 함께 본다. Dependabot 은 그 파일을
# 생태계로 인식하지 못하고, 액션 검사도 워크플로만 읽었다 — 그래서 ruff·ktlint·
# pip-audit 핀은 **아무도 낡았다고 말해주지 않았다.** 취약점 스캐너가 낡으면
# 검사가 도는 것처럼 보이면서 실제로는 덜 본다.
#
#   check-action-pins.sh [파일...]     기본값: 이 스크립트 옆의 gates.yml
#
# 뒤처진 핀이 있으면 종료코드 1.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES=("$@"); [ ${#FILES[@]} -eq 0 ] && FILES=("$SELF_DIR/gates.yml")

command -v gh >/dev/null 2>&1 || { echo "check-action-pins: gh 가 필요합니다" >&2; exit 2; }

# 조회 실패를 통과로 처리하지 않는다 — 검사가 고장 나면 조용히 통과하는 것이
# 이 킷이 반복해서 막아온 부류다.
behind=0; failed=0; checked=0
declare -a SEEN=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "check-action-pins: 파일 없음 — $f" >&2; exit 2; }
  while IFS= read -r pin; do
    case " ${SEEN[*]:-} " in *" $pin "*) continue ;; esac
    SEEN+=("$pin")
    repo=${pin%@*}; cur=${pin#*@}
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
  done < <(grep -ohE 'uses: +[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' "$f" \
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
# ── 게이트 도구 핀 ───────────────────────────────────────────────────────────
# 도구마다 "최신" 을 어디서 읽는지가 다르다. releases/latest 가 옳은 곳과 tags 를
# 봐야 하는 곳이 갈린다 — golang/tools 의 최신 릴리즈는 gopls 이고, golang/vuln 은
# 릴리즈가 태그보다 뒤처진다. 반대로 ruff 는 태그가 너무 많아 첫 페이지로는 못 찾는다.
TOOLS="
goimports:golang/tools:tags
govulncheck:golang/vuln:tags
golangci_lint:golangci/golangci-lint:release
ruff:astral-sh/ruff:release
ktlint:pinterest/ktlint:release
pip_audit:pypa/pip-audit:release
"
TV="$SELF_DIR/../gate/tool-versions"
if [ -f "$TV" ]; then
  for row in $TOOLS; do
    key=${row%%:*}; rest=${row#*:}; repo=${rest%:*}; how=${rest##*:}
    cur=$(sed -n "s/^$key=//p" "$TV" | head -1)
    [ -n "$cur" ] || { echo "  ? $key — tool-versions 에 없습니다" >&2; failed=1; continue; }
    if [ "$how" = release ]; then
      latest=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null)
    else
      latest=$(gh api "repos/$repo/tags?per_page=100" --jq '.[].name' 2>/dev/null \
               | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1)
    fi
    latest=${latest#v}
    if [ -z "$latest" ]; then
      echo "  ? $key ($repo) — 최신 버전을 조회하지 못했습니다" >&2; failed=1; continue
    fi
    checked=$((checked+1))
    if [ "${cur#v}" != "$latest" ]; then
      echo "  ✗ $key  ${cur#v} → $latest"; behind=1
    fi
  done
else
  echo "check-action-pins: tool-versions 를 찾지 못했습니다 — $TV" >&2; failed=1
fi

if [ "$failed" = 1 ]; then
  echo "check-action-pins — 조회 실패가 있어 판정할 수 없습니다" >&2; exit 2
fi
if [ "$behind" = 1 ]; then
  echo ""
  echo "위 핀이 뒤처졌습니다. 올리고 커밋하세요 — 아무도 대신 해주지 않습니다." >&2
  exit 1
fi
echo "check-action-pins ✓ ${checked}개(액션 + 게이트 도구)가 최신입니다"
