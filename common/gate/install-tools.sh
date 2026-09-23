#!/usr/bin/env bash
# 게이트가 쓰는 도구를 tool-versions 에 적힌 버전으로 설치한다.
#
#   install-tools.sh              이 레포에 필요한 것만 (언어 감지)
#   install-tools.sh --all        전부
#   install-tools.sh --dry-run    무엇을 설치할지만 출력
#
# 버전을 여기 적지 않는다 — tool-versions 가 단일 출처다.
# 런타임(go·java·node·python3)은 설치하지 않는다. 그건 프로젝트가 요구하는 버전이 있고,
# 킷이 남의 머신에 런타임을 까는 것은 선을 넘는다.
set -uo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SELF_DIR/lib.sh"
# 게이트와 같은 PATH 로 판정한다. 안 그러면 게이트는 "있다" 하고 설치기는 "없다" 해서,
# 이미 있는 도구를 다시 깔고 dry-run 이 거짓말을 한다.
gate_extend_path

DRY=0 ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "install-tools: 알 수 없는 인자 $1" >&2; exit 2 ;;
  esac
done

need=()
add() { case " ${need[*]:-} " in *" $1 "*) ;; *) need+=("$1") ;; esac; }

if [ "$ALL" = 1 ]; then
  add goimports; add golangci-lint; add govulncheck; add ruff; add ktlint
else
  # 마커는 게이트와 같은 기준으로 찾는다 — 깊이를 제한하지 않고 gate_prune_expr 로 건너뛴다.
  # 한때 maxdepth 3 이라, 네 단계 아래 go.mod 를 게이트는 검사하면서 도구가 없다며 이 스크립트를
  # 안내하는데 이 스크립트는 「필요한 도구가 없습니다」라고 답했다. -print -quit 는 첫 하나에서
  # 멈춘다. 멈추지 않으면 pipefail 아래에서 grep -q 가 먼저 끝날 때 find 가 SIGPIPE 로 죽는다.
  find . \( $(gate_prune_expr) \) -prune -o -name go.mod -print -quit 2>/dev/null | grep -q . \
    && { add goimports; add golangci-lint; add govulncheck; }
  find . \( $(gate_prune_expr) \) -prune -o -name pyproject.toml -print -quit 2>/dev/null | grep -q . && add ruff
  # ktlint 는 Kotlin 린터다. 빌드 파일만 보고 넣으면 Java 전용 프로젝트에 쓸모없는
  # 도구를 깔게 된다 — 실제 .kt 파일이 있을 때만 넣는다.
  find . -name '*.kt' -not -path '*/build/*' -print -quit 2>/dev/null | grep -q . && add ktlint
fi

[ ${#need[@]} -eq 0 ] && { echo "install-tools — 이 레포에 필요한 도구가 없습니다."; exit 0; }

installed=(); skipped=(); failed=()
for t in "${need[@]}"; do
  if gate_have "$t"; then skipped+=("$t (이미 있음: $(command -v "$t"))"); continue; fi
  hint=$(gate_install_hint "$t")
  if [ "$DRY" = 1 ]; then echo "  설치 예정  $t → $hint"; continue; fi

  echo "── $t 설치 ──"
  case "$t" in
    goimports|golangci-lint|govulncheck)
      gate_have go || { failed+=("$t (go 가 없습니다 — 런타임은 직접 설치하세요)"); continue; }
      # hint 가 설치 명령이 아니라 안내문이면(버전을 못 읽은 경우) 실행하지 않는다.
      case "$hint" in
        "go install "*) ;;
        *) failed+=("$t ($hint)"); continue ;;
      esac
      # shellcheck disable=SC2086
      if eval "$hint"; then installed+=("$t"); else failed+=("$t"); fi
      ;;
    ruff)
      v=$(gate_tool_version ruff)
      [ -n "$v" ] || { failed+=("$t (고정 버전을 읽지 못했습니다)"); continue; }
      if gate_have uv; then
        uv tool install "ruff==$v" && installed+=("$t") || failed+=("$t")
      elif gate_have pipx; then
        pipx install "ruff==$v" && installed+=("$t") || failed+=("$t")
      else
        failed+=("$t (uv 도 pipx 도 없습니다 — $hint)")
      fi
      ;;
    ktlint)
      v=$(gate_tool_version ktlint)
      [ -n "$v" ] || { failed+=("$t (고정 버전을 읽지 못했습니다)"); continue; }
      dest="${AI_KIT_BIN_DIR:-$HOME/.local/bin}"
      mkdir -p "$dest" || { failed+=("$t ($dest 를 만들지 못했습니다)"); continue; }
      if curl -fsSL -o "$dest/ktlint" \
           "https://github.com/pinterest/ktlint/releases/download/${v}/ktlint" \
         && chmod +x "$dest/ktlint"; then
        installed+=("$t → $dest/ktlint")
        case ":$PATH:" in *":$dest:"*) ;; *) echo "  주의: $dest 가 PATH 에 없습니다." ;; esac
      else failed+=("$t"); fi
      ;;
    *) failed+=("$t (설치 방법이 정의돼 있지 않습니다)") ;;
  esac
done

[ "$DRY" = 1 ] && exit 0
echo ""
echo "install-tools — 설치 ${#installed[@]} · 이미있음 ${#skipped[@]} · 실패 ${#failed[@]}"
[ ${#installed[@]} -gt 0 ] && printf '  ✓ %s\n' "${installed[@]}"
[ ${#skipped[@]}   -gt 0 ] && printf '  · %s\n' "${skipped[@]}"
if [ ${#failed[@]} -gt 0 ]; then printf '  ✗ %s\n' "${failed[@]}" >&2; exit 1; fi
exit 0
