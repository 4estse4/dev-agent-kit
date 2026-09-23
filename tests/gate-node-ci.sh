#!/usr/bin/env bash
# CI 의 setup-node 는 레포 루트의 .nvmrc 로 node 를 깔고, 실패를 덮지 않는다.
#
# 이 테스트가 있는 이유: gates.yml 의 setup-node 둘이 루트의 .nvmrc 와 lockfile 을 가정했고,
# 둘 다 continue-on-error 라 실패가 초록으로 덮였다(이슈 #95). lockfile 이 하위 디렉터리에만 있는
# 레포에서 gate 잡의 setup-node 가 「Dependencies lock file is not found」로 매번 실패했는데,
# API 는 그 스텝을 success 로 줬다.
#
# 깨끗한 레포에 킷을 설치하고 그 gates.yml 을 읽는다. 보는 것:
#   · actions/setup-node 를 쓰는 스텝마다 continue-on-error 가 없고, 같은 잡에서 그보다 앞선
#     스텝이 gate_nvmrc_check 를 부르고, cache: npm 이면 cache-dependency-path 도 있다(없으면
#     setup-node 가 레포 루트에서만 lockfile 을 찾는다)
#   · 그 확인 스텝의 run 을 설치한 레포에서 돌리면, 루트에 .nvmrc 가 없을 때(하위 디렉터리에만
#     있을 때도) 이유를 말하며 실패하고, 있으면 통과한다. 러너의 기본 셸처럼 `bash -e` 로 돈다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
Y="$R/.github/workflows/gates.yml"
[ -f "$Y" ] || { echo "  ✗ $Y 가 없다 — 설치 경로가 바뀌었나"; exit 1; }

ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# setup-node 스텝마다 판정한다. 주석 줄은 보지 않는다.
report=$(awk '
  function endstep() {
    if (step ~ /uses: actions\/setup-node@/) {
      n++; msg = ""
      if (step ~ /continue-on-error:/) msg = msg " continue-on-error 가 있다."
      if (!checked) msg = msg " 앞에서 gate_nvmrc_check 를 안 부른다."
      if (step ~ /cache: *npm/ && step !~ /cache-dependency-path:/) msg = msg " cache: npm 인데 cache-dependency-path 가 없다."
      print (msg == "" ? "ok" : "bad") "\t" job "\t" msg
    }
    if (hit) checked = 1
    step = ""; hit = 0
  }
  /^jobs:$/ { injobs = 1; next }
  !injobs { next }
  /^  [a-z_-]+:$/ { endstep(); job = $1; sub(/:$/, "", job); checked = 0; next }
  /^      - / { endstep() }
  /^[[:space:]]*#/ { next }
  { step = step $0 "\n"; if ($0 ~ /gate_nvmrc_check/) hit = 1 }
  END { endstep(); if (!n) print "none" }
' "$Y")
case "$report" in
  none) bad "setup-node 를 쓰는 스텝이 하나도 안 걸렸다 — gates.yml 이 바뀌었나" ;;
  *)
    while IFS=$'\t' read -r st job msg; do
      if [ "$st" = ok ]; then ok "$job 잡의 setup-node 는 앞에서 루트 .nvmrc 를 보고, 실패를 덮지 않고, lockfile 을 루트에서만 찾지 않는다"
      else bad "$job 잡의 setup-node:$msg"; fi
    done <<< "$report"
    ;;
esac

# gate_nvmrc_check 를 부르는 스텝의 run 을 잡마다 파일로 뽑는다.
awk -v out="$T/step." '
  function flush() { if (body != "" && hit) { f = out job; printf "%s", body > f; close(f) } body = ""; hit = 0; inrun = 0 }
  /^jobs:$/ { injobs = 1; next }
  !injobs { next }
  /^  [a-z_-]+:$/ { flush(); job = $1; sub(/:$/, "", job); next }
  /^      - / { flush() }
  inrun && /^          / { l = $0; sub(/^          /, "", l); body = body l "\n"; if (l !~ /^[[:space:]]*#/ && l ~ /gate_nvmrc_check/) hit = 1; next }
  inrun { inrun = 0 }
  /^ +(- )?run: *\|$/ { inrun = 1; next }
  /^ +(- )?run: / { l = $0; sub(/^ +(- )?run: */, "", l); body = l "\n"; if (l ~ /gate_nvmrc_check/) hit = 1 }
  END { flush() }
' "$Y"

nvmrcs() { # 인자=.nvmrc 를 둘 디렉터리(. 이면 루트). 없으면 아무 데도 안 둔다
  local d
  rm -rf "$R/.nvmrc" "$R/web"
  for d in "$@"; do mkdir -p "$R/$d"; echo 22 > "$R/$d/.nvmrc"; done
}

check() { # $1=잡  $2=설명  $3=기대(fail|pass)  나머지=nvmrcs 인자
  local job="$1" what="$2" want="$3" out rc; shift 3
  nvmrcs "$@"
  out=$(cd "$R" && bash -e "$T/step.$job" 2>&1); rc=$?
  if [ "$want" = fail ]; then
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '::error::.*\.nvmrc'; then ok "$job · $what → 이유를 말하며 실패"
    else bad "$job · $what → rc=$rc, .nvmrc 를 말하며 실패해야 한다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'; fi
  else
    if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '::error'; then ok "$job · $what → 통과"
    else bad "$job · $what → rc=$rc, 통과해야 한다:"; printf '%s\n' "$out" | cut -c1-120 | sed 's/^/      /'; fi
  fi
}

steps=$(cd "$T" && ls step.* 2>/dev/null | sed 's/^step\.//')
[ -n "$steps" ] || bad "gate_nvmrc_check 를 부르는 스텝이 하나도 안 뽑혔다"
for job in $steps; do
  check "$job" ".nvmrc 없음"            fail
  check "$job" "web/.nvmrc 에만 있음"   fail web
  check "$job" "루트 .nvmrc"            pass .
done

rm -rf "$T"
exit $fail
