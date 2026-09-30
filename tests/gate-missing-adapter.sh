#!/usr/bin/env bash
# --lang 으로 뺀 언어의 모듈이 생기면, 게이트는 그 언어를 넣어 다시 설치하라고 안내한다.
#
# 이 테스트가 있는 이유: `--lang py,ts` 로 설치한 레포에 go.mod 를 더하면 게이트가 `go(어댑터 없음)` 으로
# 실패하는데, 안내는 도구가 없을 때의 것이었다 — 「런타임이다 — 프로젝트가 요구하는 버전을 설치한다」와
# install-tools.sh(이슈 #173). 어댑터가 없는 까닭은 도구가 아니라 설치 범위다.
#
# install.sh 는 --lang 을 주면 install-manifest 의 langs 를 이어받지 않고 고르지 않은 언어의 어댑터를
# 지운다. 그래서 안내는 langs 에 그 언어를 더한 목록 전체를 적어야 한다. 그 언어 하나만 적으면 그
# 명령이 나머지 언어를 뺀다.
#
# 깨끗한 레포에 `--lang py,ts` 로 설치하고 go.mod 를 더한 뒤 gate.sh 를 실행한다. 보는 것:
#   · 그대로면 실패하고, `--lang py,ts,go` 를 적고, 도구 설치 안내는 적지 않는다
#   · install-manifest 에 langs 줄이 없거나 파일이 없으면 실패하고, 못 읽었다고 적고, --lang 목록을
#     짐작해 적지 않는다
#   · KIT_ALLOW_MISSING_TOOLS=1 이면 통과하고 건너뜀 줄에 올린다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" --lang py,ts > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
[ -f "$R/.kit/gate/adapters/go.sh" ] && { echo "  ✗ --lang py,ts 로 설치했는데 go 어댑터가 있다 — 설치기가 바뀌었나"; exit 1; }
mkdir -p "$R/backend"; printf 'module example.com/m\n\ngo 1.25\n' > "$R/backend/go.mod"
M="$R/.kit/install-manifest"; cp "$M" "$T/manifest"

ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# 게이트를 실행하고 go 어댑터의 실패 블록을 뽑는다. 다른 검사의 블록은 보지 않는다.
run_gate() { # 인자=앞에 붙일 환경 변수
  out=$(cd "$R" && env "$@" bash .kit/gate/gate.sh --all 2>&1); rc=$?
  block=$(printf '%s\n' "$out" | awk '/^──── go\(어댑터 없음\) ────$/ { on = 1; print; next } on && (/^──── / || /^gate /) { on = 0 } on')
}
show() { printf '%s\n' "$out" | tail -12 | sed 's/^/      /'; }

run_gate KIT_ALLOW_MISSING_TOOLS=0
if [ "$rc" -eq 0 ] || [ -z "$block" ]; then bad "그대로 → rc=$rc, go(어댑터 없음) 블록을 내며 실패해야 한다:"; show
else
  printf '%s\n' "$block" | grep -qF -- '--lang py,ts,go' && ok "그대로 → --lang py,ts,go 를 적는다" \
    || { bad "그대로 → --lang py,ts,go 를 적어야 한다:"; show; }
  if printf '%s\n' "$block" | grep -qe '런타임이다' -e 'install-tools.sh'; then bad "그대로 → 도구 설치 안내를 적었다:"; show
  else ok "그대로 → 도구 설치 안내를 적지 않는다"; fi
fi

for how in "langs 줄이 없다" "install-manifest 가 없다"; do
  if [ "$how" = "langs 줄이 없다" ]; then grep -v '^langs=' "$T/manifest" > "$M"; else rm -f "$M"; fi
  run_gate KIT_ALLOW_MISSING_TOOLS=0
  if [ "$rc" -eq 0 ] || [ -z "$block" ]; then bad "$how → rc=$rc, go(어댑터 없음) 블록을 내며 실패해야 한다:"; show
  elif ! printf '%s\n' "$block" | grep -q '읽지 못했'; then bad "$how → langs 를 읽지 못했다고 적어야 한다:"; show
  elif printf '%s\n' "$block" | grep -qE -- '--lang [a-z]'; then bad "$how → --lang 목록을 짐작해 적었다:"; show
  else ok "$how → 읽지 못했다고 적고 --lang 목록을 적지 않는다"; fi
  cp "$T/manifest" "$M"
done

run_gate KIT_ALLOW_MISSING_TOOLS=1
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^gate — 건너뜀.*go(어댑터 없음)'; then ok "KIT_ALLOW_MISSING_TOOLS=1 → 통과하고 건너뜀 줄에 올린다"
else bad "KIT_ALLOW_MISSING_TOOLS=1 → rc=$rc, 통과하고 건너뜀 줄에 올려야 한다:"; show; fi

rm -rf "$T"
exit $fail
