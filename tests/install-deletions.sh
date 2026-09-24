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
  # 훅은 재설치가 절대 안 지운다
  for p in pre-commit pre-push; do
    [ -e "$R/.ai-kit/git-hooks/$p" ] || { echo "  ✗ [$what] 훅이 사라졌다: $p"; fail=1; bad=1; }
  done
  [ "$bad" = 0 ] && echo "  ✓ $what"
  return 0
}

check "게이트만"        --hooks
check "전체 플래그"      --hooks --templates --lint --ci --agent
check "언어를 좁힌 재설치" --hooks --lang py

# 미리보기와 실제가 같은 수를 내는가.
#
# **두 출력이 같은 낱말을 쓰므로 정규식 한 벌로 다섯 칸을 통째로 비교한다.** 예전에는
# 칸마다 이름이 달라(`새 파일`/`설치`, `옆에 놓임`/`충돌`) 정규식을 두 벌 써야 했고,
# 그러다 `옆에 놓임` 칸을 아예 안 뽑아 비교에서 빠뜨렸다.
#
# **단계마다 그 칸이 0 이 아니어야 확인한 것이다.** 0 = 0 은 칸이 틀려도 맞으므로 아무것도
# 보증하지 않는다 — 첫 판이 그랬고, 미리보기의 건수만 거짓으로 만들어도 초록이었다.
cols() { sed -n 's/.*지금 설치하면 — \(.*\)/\1/p; s/^\(설치 [0-9].*\) · 경고 [0-9]*$/\1/p'; }
R=$(mkrepo)
for phase in 첫설치 재설치 교체있음 보존있음 삭제있음; do
  case "$phase" in
    # 킷 소유 파일을 고쳐두면 재설치가 그것을 되돌린다 = `교체`. 이 칸을 안 만들면
    # 네 단계가 전부 `교체 0` 이라 그 칸이 갈려도 초록이다 — PR 본문이 "여섯 개를
    # 교체하고도 교체 0건" 이라고 적은 그 결함의 칸이 바로 여기다.
    교체있음) echo '# 프로젝트가 킷 파일을 고쳐둠' >> "$R/.ai-kit/gate/gate.sh" ;;
    # 프로젝트 소유는 둘이다 — CLAUDE.md 와 .claude/settings.json. 하나만 고쳐두면
    # 다른 하나의 소유 판정이 깨져도 이 검사가 실패하지 않는다(실행해 확인함: settings.json 쪽을
    # 킷 소유로 오판하게 만들어도 초록이었다).
    보존있음) printf '\n# 이 프로젝트가 적은 줄\n' >> "$R/CLAUDE.md"
              python3 - "$R/.claude/settings.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["permissions"]["allow"].append("Bash(echo project-owned)")
json.dump(d, open(p,"w"), indent=2, ensure_ascii=False)
PYEOF
              ;;
    삭제있음) echo x > "$R/.ai-kit/git-hooks/README.md" ;;
  esac
  f=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent --dry-run "$R" 2>&1 | cols)
  a=$(bash "$KIT/install.sh" --hooks --templates --lint --ci --agent          "$R" 2>&1 | cols)
  if [ "$f" = "$a" ]; then echo "  ✓ 미리보기=실제 ($phase: $f)"
  else echo "  ✗ 미리보기≠실제 ($phase)"; echo "      미리보기 [$f]"; echo "      실제     [$a]"; fail=1; fi
  # 그 단계가 겨눈 칸이 0 이면 확인한 것이 아니다
  case "$phase" in
    교체있음) echo "$a" | grep -q '교체 0' && { echo "  ✗ $phase 인데 교체 칸이 0 이다 — 이 칸은 확인하지 않은 것과 같다"; fail=1; } ;;
    보존있음) echo "$a" | grep -q '보존 0' && { echo "  ✗ $phase 인데 보존 칸이 0 이다 — 이 칸은 확인하지 않은 것과 같다"; fail=1; } ;;
    삭제있음) echo "$a" | grep -q '삭제 0' && { echo "  ✗ $phase 인데 삭제 칸이 0 이다 — 이 칸은 확인하지 않은 것과 같다"; fail=1; } ;;
  esac
done

exit $fail
