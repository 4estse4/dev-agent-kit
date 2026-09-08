#!/usr/bin/env bash
# install.sh 가 "지웠다" 고 말한 것과 실제로 사라진 것이 같은가.
#
# 이 테스트가 있는 이유: 한 라운드에 삭제 집계가 **안 지운 pre-commit·pre-push 를 지웠다고
# 보고**했다. 원인은 목록을 LC_ALL=C 로 정렬해놓고 comm 은 세션 로케일로 비교한 것이었고,
# 깨진 채로도 사람 눈에는 그럴듯해 보였다. 잡은 것은 사람이었다 — 그래서 CI 로 옮긴다.
#
# 결함이 살아 있을 때 이 스크립트가 빨간 것을 확인하고 고쳤다. 되돌리면 다시 빨개진다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

# 정렬해서 비교하지 않는다. 그것이 이 회귀의 원인이었다 — 목록은 LC_ALL=C 로 정렬하고
# comm 은 세션 로케일로 비교해서, 대문자로 시작하는 파일 하나에 병합이 어긋났다.
# 고친 방식이 "정렬을 없앤다" 였으므로 가드도 그것이다. 로케일에 안 기댄다.
if grep -qE '\bcomm -|\bjoin ' "$KIT/install.sh"; then
  echo "  ✗ install.sh 가 정렬된 목록을 병합한다(comm/join) — 정렬 기준이 둘이 되면 어긋난다"
  fail=1
else
  echo "  ✓ 정렬해서 비교하는 자리 없음"
fi

mkrepo() { local d; d=$(mktemp -d)/repo; mkdir -p "$d"
  git init -q "$d"; git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '%s' "$d"; }

# 말한 것 == 실제 사라진 것 인가
check() { # $1=설명  나머지=install.sh 플래그
  local what="$1"; shift
  local bad=0
  local R; R=$(mkrepo)
  bash "$KIT/install.sh" "$@" "$R" >/dev/null 2>&1
  # 킷이 안 놓는 파일을 하나 둔다 — 재설치가 지우는 정상 상황이고,
  # 대문자로 시작해야 C 정렬과 로케일 정렬이 갈린다.
  echo x > "$R/.ai-kit/git-hooks/README.md"
  local before; before=$(cd "$R" && find .ai-kit -type f)
  local out;    out=$(bash "$KIT/install.sh" "$@" "$R" 2>&1)
  local said;   said=$(printf '%s\n' "$out" | sed -n 's/^  - \([^ ]*\).*/\1/p')
  local p
  for p in $said; do
    [ -e "$R/$p" ] && { echo "  ✗ [$what] 지웠다면서 남아 있다: $p"; fail=1; bad=1; }
  done
  while IFS= read -r p; do
    [ -n "$p" ] && [ ! -e "$R/$p" ] && ! printf '%s\n' $said | grep -qx "$p" \
      && { echo "  ✗ [$what] 말없이 사라졌다: $p"; fail=1; bad=1; }
  done <<< "$before"
  # 강제 계층은 재설치가 절대 안 지운다
  for p in pre-commit pre-push; do
    [ -e "$R/.ai-kit/git-hooks/$p" ] || { echo "  ✗ [$what] 훅이 사라졌다: $p"; fail=1; bad=1; }
  done
  [ "$bad" = 0 ] && echo "  ✓ $what"
  return 0
}

check "게이트만"        --hooks
check "전체 플래그"      --hooks --templates --lint --ci --agent
check "언어를 좁힌 재설치" --hooks --lang py

# 예고와 실제가 같은 수를 내는가.
#
# **삭제가 0 이 아닌 경우를 반드시 포함한다.** 0=0 은 그 칸이 틀려도 통과하므로 아무것도
# 보증하지 않는다 — 이 테스트의 첫 판이 그랬고, 예고의 건수만 거짓으로 만들어도 초록이었다.
R=$(mkrepo)
for phase in 첫설치 재설치 지움있는재설치; do
  [ "$phase" = 지움있는재설치 ] && echo x > "$R/.ai-kit/git-hooks/README.md"
  f=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent --dry-run "$R" 2>&1 \
      | sed -n 's/.*새 파일 \([0-9]*\) · 킷이 교체 \([0-9]*\).*그대로 \([0-9]*\) · 지움 \([0-9]*\)/\1 \2 \3 \4/p')
  a=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent "$R" 2>&1 \
      | sed -n 's/^설치 \([0-9]*\)건 · 교체 \([0-9]*\)건 · 삭제 \([0-9]*\)건 · 건너뜀 \([0-9]*\)건.*/\1 \2 \4 \3/p')
  [ "$f" = "$a" ] && echo "  ✓ 예고=실제 ($phase: $f)" \
                  || { echo "  ✗ 예고≠실제 ($phase): 예고 [$f] vs 실제 [$a]"; fail=1; }
  # 마지막 경우는 삭제 칸이 0 이면 안 된다 — 0 이면 이 검사가 그 칸을 안 잰 것이다
  if [ "$phase" = 지움있는재설치 ]; then
    case "$f" in *" 0") echo "  ✗ 지움있는재설치인데 예고의 삭제 칸이 0 이다 — 이 경우를 안 잰 셈"; fail=1 ;; esac
  fi
done
exit $fail
