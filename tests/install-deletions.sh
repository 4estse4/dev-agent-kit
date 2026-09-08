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

# 예고와 실제가 같은 수를 내는가
R=$(mkrepo)
for phase in 첫설치 재설치; do
  f=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent --dry-run "$R" 2>&1 \
      | sed -n 's/.*새 파일 \([0-9]*\) · 킷이 교체 \([0-9]*\).*그대로 \([0-9]*\) · 지움 \([0-9]*\)/\1 \2 \3 \4/p')
  a=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent "$R" 2>&1 \
      | sed -n 's/^설치 \([0-9]*\)건 · 교체 \([0-9]*\)건 · 삭제 \([0-9]*\)건 · 건너뜀 \([0-9]*\)건.*/\1 \2 \4 \3/p')
  [ "$f" = "$a" ] && echo "  ✓ 예고=실제 ($phase: $f)" \
                  || { echo "  ✗ 예고≠실제 ($phase): 예고 [$f] vs 실제 [$a]"; fail=1; }
done
exit $fail
