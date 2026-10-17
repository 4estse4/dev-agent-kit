#!/usr/bin/env bash
# 설치기가 `.kit/drafts/`(세션이 PR 본문 · 코멘트 조각을 두는 자리)를 남기는가.
#
# 이 테스트가 있는 이유: `.kit/` 는 설치할 때마다 통째로 비우고 놓는 자리이고, 킷이 놓지 않은 파일이 든 `.kit/` 를
# 보면 설치를 멈춘다. 조각 자리를 그 아래에 두자(이슈 #107) 두 가지가 생겼다(데모 레포에서 실제로 확인함).
#   · 전체 설치 뒤 조각을 만들고 다시 설치하면 조각을 지우고 「삭제」로 보고했다
#   · `--agent` 로 설치하고 조각을 만든 뒤 `--hooks` 를 설치하면 「킷이 설치한 것이 아닙니다」로 멈췄다
# 조각은 설치된 `drafts.sh` 로 만든다 — 세션이 조각을 만드는 길이 그것이다.
#
# 멈추는 판정은 가드라 조각 자리만 빼고 그대로 발동해야 한다. 조각 자리와 이름이 비슷한 디렉터리와, 조각 자리와
# 함께 있는 다른 파일로도 본다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

mkrepo() { local d; d=$(mktemp -d)/${1:-repo}; mkdir -p "$d"
  git init -q "$d"; git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  printf '%s' "$d"; }
# 설치된 drafts.sh 로 조각 자리를 만들고 조각 하나를 쓴다. 조각 디렉터리를 낸다
draft() { local d; d=$(cd "$1" && bash .claude/skills/open-pr/drafts.sh pr-body) || return 1
  printf '## 문제\n' > "$d/10-head.part"; printf '%s' "$d"; }
cols() { sed -n 's/.*지금 설치하면 — \(.*\)/\1/p; s/^\(설치 [0-9].*\) · 경고 [0-9]*$/\1/p'; }

# 1. 전체 설치 뒤의 재설치 — 미리보기와 실제가 조각을 지우지 않고, 같은 건수를 낸다
R=$(mkrepo); bash "$KIT/install.sh" "$R" >/dev/null 2>&1
if d=$(draft "$R"); then
  f=$(bash "$KIT/install.sh" --dry-run "$R" 2>&1); a=$(bash "$KIT/install.sh" "$R" 2>&1)
  for o in "미리보기:$f" "실제:$a"; do
    if printf '%s' "${o#*:}" | grep -qF '.kit/drafts'; then bad "${o%%:*} 출력이 조각 자리를 적었다:"; printf '%s\n' "${o#*:}" | grep -F '.kit/drafts' | sed 's/^/      /'
    else ok "${o%%:*} 출력에 조각 자리가 없다"; fi
  done
  if [ "$(printf '%s\n' "$f" | cols)" = "$(printf '%s\n' "$a" | cols)" ]; then ok "미리보기=실제 ($(printf '%s\n' "$a" | cols))"
  else bad "미리보기≠실제"; echo "      미리보기 [$(printf '%s\n' "$f" | cols)]"; echo "      실제     [$(printf '%s\n' "$a" | cols)]"; fi
  if [ -f "$d/10-head.part" ] && [ -f "$R/.kit/drafts/.gitignore" ]; then ok "재설치 뒤 조각과 .gitignore 가 남아 있다"
  else bad "재설치 뒤 조각 $([ -f "$d/10-head.part" ] && echo 있음 || echo 없음) · .gitignore $([ -f "$R/.kit/drafts/.gitignore" ] && echo 있음 || echo 없음)"; fi
else
  bad "설치된 drafts.sh 로 조각 자리를 만들지 못했다"
fi

# 2. `--agent` 뒤 조각이 있을 때 `--hooks` — 미리보기와 실제 모두 멈추지 않는다
for mode in 미리보기 실제; do
  flag=""; [ "$mode" = 미리보기 ] && flag=--dry-run
  R=$(mkrepo); bash "$KIT/install.sh" --agent "$R" >/dev/null 2>&1
  if d=$(draft "$R"); then
    out=$(bash "$KIT/install.sh" --hooks $flag "$R" 2>&1); rc=$?
    if [ "$rc" = 0 ] && [ -f "$d/10-head.part" ] && ! printf '%s' "$out" | grep -qF '킷이 설치한 것이 아닙니다'; then
      ok "$mode: --agent 뒤 조각이 있어도 --hooks 설치가 멈추지 않고 조각이 남는다"
    else
      bad "$mode: --agent 뒤 조각이 있을 때 --hooks → rc=$rc · 조각 $([ -f "$d/10-head.part" ] && echo 있음 || echo 없음)"
      printf '%s\n' "$out" | grep -F '킷이 설치한 것이 아닙니다' | sed 's/^/      /'
    fi
  else
    bad "$mode: 설치된 drafts.sh 로 조각 자리를 만들지 못했다"
  fi
done

# 3. 가드는 조각 자리 밖의 파일에는 그대로 발동한다
for mode in 미리보기 실제; do
  flag=""; [ "$mode" = 미리보기 ] && flag=--dry-run
  for f in drafts-old/x drafts.bak "drafts/x 와 local.conf"; do
    R=$(mkrepo)
    case "$f" in
      "drafts/x 와 local.conf") mkdir -p "$R/.kit/drafts"; echo keep > "$R/.kit/drafts/x"; echo keep > "$R/.kit/local.conf"; k="$R/.kit/local.conf" ;;
      *) mkdir -p "$(dirname "$R/.kit/$f")"; echo keep > "$R/.kit/$f"; k="$R/.kit/$f" ;;
    esac
    out=$(bash "$KIT/install.sh" --hooks $flag "$R" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [ "$(cat "$k")" = keep ] && [ ! -e "$R/.kit/install-manifest" ] \
       && printf '%s' "$out" | grep -qF '킷이 설치한 것이 아닙니다'; then
      ok "$mode: .kit/$f 가 있으면 지우지 않고 멈춘다"
    else
      bad "$mode: .kit/$f 가 있는데 rc=$rc · 내용=[$(cat "$k" 2>/dev/null)]"
    fi
  done
done

# 4. 레포 경로에 find 패턴 글자(`[` 등)가 있어도 판정이 조각 자리를 빼고, 다른 파일에는 그대로 발동한다.
# 한때 판정만 절대 경로를 `-path` 패턴으로 써서, `proj[1]` 같은 경로에서 조각 자리를 빼지 못해 멈췄다(PR #246 1라운드 콜드 리뷰).
for mode in 미리보기 실제; do
  flag=""; [ "$mode" = 미리보기 ] && flag=--dry-run
  R=$(mkrepo 'proj[1]'); bash "$KIT/install.sh" --agent "$R" >/dev/null 2>&1
  if d=$(draft "$R"); then
    out=$(bash "$KIT/install.sh" --hooks $flag "$R" 2>&1); rc=$?
    if [ "$rc" = 0 ] && [ -f "$d/10-head.part" ] && ! printf '%s' "$out" | grep -qF '킷이 설치한 것이 아닙니다'; then
      ok "$mode: 경로에 [1] 이 든 레포도 --agent 뒤 조각이 있을 때 --hooks 설치가 멈추지 않는다"
    else
      bad "$mode: 경로에 [1] 이 든 레포에서 --hooks → rc=$rc · 조각 $([ -f "$d/10-head.part" ] && echo 있음 || echo 없음)"
    fi
  else
    bad "$mode: 경로에 [1] 이 든 레포에서 설치된 drafts.sh 로 조각 자리를 만들지 못했다"
  fi
  R=$(mkrepo 'proj[1]'); mkdir -p "$R/.kit/drafts"; echo keep > "$R/.kit/drafts/x"; echo keep > "$R/.kit/local.conf"
  out=$(bash "$KIT/install.sh" --hooks $flag "$R" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && [ "$(cat "$R/.kit/local.conf")" = keep ] && printf '%s' "$out" | grep -qF '킷이 설치한 것이 아닙니다'; then
    ok "$mode: 경로에 [1] 이 든 레포도 .kit/local.conf 가 있으면 지우지 않고 멈춘다"
  else
    bad "$mode: 경로에 [1] 이 든 레포에서 .kit/local.conf 가 있는데 rc=$rc · 내용=[$(cat "$R/.kit/local.conf" 2>/dev/null)]"
  fi
done

exit $fail
