#!/usr/bin/env bash
# merge-pr 이 git worktree 에서도 머지 뒤 브랜치를 지우고 base 브랜치로 돌아가는가(이슈 #91).
#
# 이 테스트가 있는 이유: 머지 명령이 `gh pr merge --delete-branch` 였다. gh 는 머지 뒤 로컬 브랜치를
# 먼저 지우는데, worktree 에서는 거기서 실패한다. detached 면 현재 브랜치를 못 읽고, PR 브랜치에 있으면
# base 로 옮기려는데 base 를 원래 체크아웃이 쓰고 있다. 그러면 gh 는 원격 브랜치 삭제도 건너뛰고
# rc=1 로 끝나 머지가 실패한 것처럼 보인다. 4절의 `git checkout main` 도 같은 이유로 worktree 에서
# 실패했다.
#
# 스킬 글에서 명령을 꺼내 실행한다. 보는 것:
#   · 3절의 머지 명령에 --delete-branch 가 없다
#   · 4절의 명령 가운데 브랜치를 지우는 것(git push · git branch -D)은 킷 settings.json 의 ask 규칙에
#     맞는다. 원격 삭제가 gh pr merge 의 ask 밖으로 나오므로 따로 사람을 거쳐야 한다
#   · fork 에서 온 PR 이면 원격 삭제를 하지 않는다. 조건이 글에 있어 실행으로는 못 보므로, 2절이
#     isCrossRepository 를 받고 4절이 그것을 쓰는지 글자로 본다
#   · 4절의 명령을 bare origin 이 있는 스크래치 레포에서 원래 체크아웃과 worktree 의 여러 상태로 실행하면
#     끝 상태가 맞다. 원격 브랜치 · 로컬 브랜치 · HEAD · 원래 체크아웃을 본다
#   · worktree 에서 fetch 가 실패하면 base 복귀 줄이 실패하고, 받아 둔 옛 origin/<base> 에 detach 하지 않는다
#   · 원래 체크아웃이 다른 브랜치에 있어도 worktree 는 base 브랜치로 옮기지 않고 detach 한다. worktree 가
#     base 에 있으면 원래 체크아웃이 base 로 옮기지 못한다(이슈 #121). 그때 base 를 쓰는 체크아웃이 없으면
#     로컬 base 는 머지된 커밋으로 갱신된다. 원래 체크아웃이 base 에 있어 갱신이 거부돼도 줄은 성공한다
#   · 원래 체크아웃에서 다른 worktree 가 base 를 쓰면 detach 한다. 원래 체크아웃의 하위 디렉터리에서 실행해도
#     원래 체크아웃으로 판정한다
#
# 스크래치 레포는 git 의 기본 브랜치 설정과 상관없이 main 으로 만든다. 한때 설정에 기대어, 설정이 있는
# 기계에서만 통과하고 CI 에서는 다섯 경우가 모두 실패했다. setup 이 머지된 커밋을 origin 에 올리지 못하면
# 스킬의 결함이 아니라 setup 실패로 보고한다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$KIT/claude-code/skills/merge-pr/SKILL.md"
SET="$KIT/claude-code/settings.json"
T=$(mktemp -d)
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# ── 3절: 머지 명령 ──
m=$(grep -E '^    gh pr merge <N>' "$SK")
if [ -z "$m" ]; then bad "3절의 머지 명령(\`    gh pr merge <N>\`)을 못 찾았다"
else
  case "$m" in
    *--delete-branch*) bad "3절의 머지 명령이 --delete-branch 를 쓴다 — worktree 에서 로컬 삭제가 실패하면 원격 삭제도 건너뛴다" ;;
    *) ok "3절의 머지 명령이 --delete-branch 를 쓰지 않는다" ;;
  esac
fi

# ── fork 에서 온 PR ── origin 의 같은 이름 브랜치는 base 레포의 다른 브랜치다. gh 도 이 경우 원격
# 삭제를 건너뛰었다(v2.92.0 `deleteRemoteBranch` 의 crossRepoPR).
v=$(grep -E '^- `gh pr view <N> --json [A-Za-z,]*`' "$SK")
s4=$(awk '/^## 4\./{s=1} /^## 5\./{s=0} s' "$SK")
case "$v" in
  *isCrossRepository*)
    case "$s4" in
      *isCrossRepository*) ok "2절이 isCrossRepository 를 받고 4절이 그것으로 fork PR 의 원격 삭제를 가른다" ;;
      *) bad "2절은 isCrossRepository 를 받지만 4절이 그것을 쓰지 않는다" ;;
    esac ;;
  *) bad "2절의 gh pr view 가 isCrossRepository 를 받지 않는다 — fork PR 이면 base 레포의 같은 이름 브랜치를 지운다" ;;
esac

# ── 4절: 명령 ── `## 4.` 부터 `## 5.` 앞까지, 4칸 들여쓴 줄 가운데 `$` 로 시작하지 않는 것
# (`$` 로 시작하는 줄은 실행 결과를 보여 주는 예시다)
awk '/^## 4\./{s=1; next} /^## 5\./{s=0} s && /^    [^ $]/ { sub(/^    /, ""); print }' "$SK" > "$T/cmds"
if [ ! -s "$T/cmds" ]; then bad "4절에서 명령을 못 찾았다"; rm -rf "$T"; exit 1; fi

# 지우는 명령은 ask 규칙에 맞아야 한다. 규칙은 `Bash(<glob>)` 이고, 명령 문자열 전체가 그 glob 에 맞는지 본다.
out=$(python3 - "$SET" "$T/cmds" <<'PY'
import fnmatch, json, re, sys
ask = [r[5:-1] for r in json.load(open(sys.argv[1]))["permissions"]["ask"] if r.startswith("Bash(")]
bad = 0
for c in open(sys.argv[2]).read().splitlines():
    c = re.sub(r"\s+#.*$", "", c).strip()
    if re.match(r"git (push|branch -D)\b", c):
        if any(fnmatch.fnmatchcase(c, g) for g in ask):
            print(f"✓ {c}")
        else:
            print(f"✗ {c} — 맞는 ask 규칙이 없다")
            bad = 1
sys.exit(bad)
PY
)
if [ $? -eq 0 ]; then ok "4절의 삭제 명령이 모두 ask 규칙에 맞는다 ($(printf '%s\n' "$out" | grep -c '^✓')개)"
else bad "4절의 삭제 명령 가운데 ask 규칙에 맞지 않는 것이 있다"; printf '%s\n' "$out" | grep '^✗' | sed 's/^/      /'; fi

gc() { git -c user.email=t@example.com -c user.name=T "$@"; }

# $1=경우 이름. origin(bare) · main(원래 체크아웃, main 브랜치) · 그 둘에 푸시한 feat 를 만든다.
# 머지를 흉내 내려고 다른 클론에서 origin/main 에 커밋 하나(스쿼시 커밋 자리)를 더 푸시한다.
# 그 커밋이 origin 의 main 에 올라가지 않았으면 setup 실패로 보고하고 1 을 반환한다.
setup() {
  local R="$T/$1"
  mkdir -p "$R"
  git init -q --bare -b main "$R/origin.git"
  git clone -q "$R/origin.git" "$R/main" 2>/dev/null
  git -C "$R/main" symbolic-ref HEAD refs/heads/main
  gc -C "$R/main" commit -q --allow-empty -m init
  git -C "$R/main" push -q -u origin main 2>/dev/null
  git -C "$R/main" switch -q -c feat
  gc -C "$R/main" commit -q --allow-empty -m feat
  git -C "$R/main" push -q -u origin feat 2>/dev/null
  git -C "$R/main" switch -q main
  git clone -q "$R/origin.git" "$R/other" 2>/dev/null
  gc -C "$R/other" commit -q --allow-empty -m squash
  git -C "$R/other" push -q origin main 2>/dev/null
  if [ "$(git -C "$R/origin.git" rev-parse -q --verify refs/heads/main)" != "$(git -C "$R/other" rev-parse HEAD)" ]; then
    bad "$1: setup 이 머지된 커밋을 origin 의 main 에 올리지 못했다 — 스킬이 아니라 테스트의 준비가 실패했다"
    return 1
  fi
}

# $1=경우 이름  $2=명령을 실행할 디렉터리. 4절의 명령을 한 줄씩 실행한다. 한 줄이 실패해도 다음 줄로 간다
# (원격 브랜치가 이미 없거나 다른 worktree 가 PR 브랜치를 쓰면 그 줄은 실패하는 것이 맞다).
# 줄마다 종료 코드를 `<경우>.rc` 에 「코드<탭>명령」으로 적는다.
run4() {
  local c rc
  while IFS= read -r c; do
    c=${c//<headRefName>/feat}; c=${c//<baseRefName>/main}
    ( cd "$2" && bash -c "$c" ) >> "$T/$1.log" 2>&1; rc=$?
    printf '%s\t%s\n' "$rc" "$c" >> "$T/$1.rc"
  done < "$T/cmds"
}

# 끝 상태를 하나씩 본다. $1=경우 이름  $2=설명  $3=명령을 실행한 디렉터리
# $4=로컬 PR 브랜치(gone · kept)  $5=HEAD(branch · detached)  $6=원래 체크아웃의 머지 전 HEAD(비면 안 본다)
check() {
  local R="$T/$1" label=$2 dir=$3 want_local=$4 want_head=$5 main_before=$6 msg=""
  git -C "$R/origin.git" rev-parse -q --verify refs/heads/feat >/dev/null && msg="$msg 원격 feat 가 남았다."
  if [ "$want_local" = gone ]; then
    git -C "$R/main" rev-parse -q --verify refs/heads/feat >/dev/null && msg="$msg 로컬 feat 가 남았다."
  else
    git -C "$R/main" rev-parse -q --verify refs/heads/feat >/dev/null || msg="$msg 다른 worktree 가 쓰는 로컬 feat 가 지워졌다."
  fi
  local head sq
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
  sq=$(git -C "$R/other" rev-parse HEAD)
  [ "$head" = "$sq" ] || msg="$msg HEAD 가 머지된 base 가 아니다."
  case "$want_head" in
    branch) [ "$(git -C "$dir" symbolic-ref -q HEAD)" = refs/heads/main ] || msg="$msg main 브랜치에 있지 않다." ;;
    detached) git -C "$dir" symbolic-ref -q HEAD >/dev/null && msg="$msg detached 가 아니다." ;;
  esac
  if [ -n "$main_before" ]; then
    [ "$(git -C "$R/main" symbolic-ref -q HEAD)" = refs/heads/main ] && [ "$(git -C "$R/main" rev-parse HEAD)" = "$main_before" ] \
      || msg="$msg 원래 체크아웃이 바뀌었다."
  fi
  if [ -z "$msg" ]; then ok "$label"
  else bad "$label:$msg"; sed 's/^/      | /' "$T/$1.log"; fi
}

# 1) 원래 체크아웃이 PR 브랜치에 있다 — 한 체크아웃만 쓰는 흔한 경로
if setup main-on-pr; then
  git -C "$T/main-on-pr/main" switch -q feat
  run4 main-on-pr "$T/main-on-pr/main"
  check main-on-pr "원래 체크아웃이 PR 브랜치에 있다: 두 브랜치가 지워지고 main 으로 돌아와 fast-forward 된다" \
    "$T/main-on-pr/main" gone branch ""
fi

# 2) worktree 가 PR 브랜치에 있고 main 은 원래 체크아웃이 쓴다
if setup wt-on-pr; then
  git -C "$T/wt-on-pr/main" worktree add -q "$T/wt-on-pr/wt" feat 2>/dev/null
  b=$(git -C "$T/wt-on-pr/main" rev-parse HEAD)
  run4 wt-on-pr "$T/wt-on-pr/wt"
  check wt-on-pr "worktree 가 PR 브랜치에 있다: 두 브랜치가 지워지고 worktree 는 origin/main 에 detach, 원래 체크아웃은 그대로다" \
    "$T/wt-on-pr/wt" gone detached "$b"
  # worktree 갈래는 로컬 main 도 갱신하려 하는데, 원래 체크아웃이 main 에 있으면 git 이 거부한다. 그 거부가
  # base 복귀 줄을 실패시키면 세션이 거기서 멈추고 브랜치가 남는다.
  r=$(awk -F'\t' '$2 ~ /^if .*git switch/ { print $1 }' "$T/wt-on-pr.rc")
  if [ "$r" = 0 ]; then ok "worktree 가 PR 브랜치에 있다: 원래 체크아웃이 main 에 있어 로컬 main 을 갱신하지 못해도 base 복귀 줄은 성공한다"
  else bad "worktree 가 PR 브랜치에 있다: base 복귀 줄의 rc=${r:-없음} — 로컬 main 갱신이 거부된 것이 줄의 실패로 섞였다"; fi
fi

# 3) worktree 가 detached 다 — gh 가 현재 브랜치를 못 읽던 경우(PR #88)
if setup wt-detached; then
  git -C "$T/wt-detached/main" worktree add -q --detach "$T/wt-detached/wt" feat 2>/dev/null
  b=$(git -C "$T/wt-detached/main" rev-parse HEAD)
  run4 wt-detached "$T/wt-detached/wt"
  check wt-detached "worktree 가 detached 다: 두 브랜치가 지워지고 worktree 는 origin/main 에 detach, 원래 체크아웃은 그대로다" \
    "$T/wt-detached/wt" gone detached "$b"
fi

# 4) 원래 체크아웃에서 번호로 머지하는데 PR 브랜치를 다른 worktree 가 쓴다 — 로컬 브랜치는 남긴다
if setup other-wt; then
  git -C "$T/other-wt/main" worktree add -q "$T/other-wt/wt" feat 2>/dev/null
  run4 other-wt "$T/other-wt/main"
  check other-wt "다른 worktree 가 PR 브랜치를 쓴다: 원격만 지워지고 그 로컬 브랜치는 남으며 main 은 fast-forward 된다" \
    "$T/other-wt/main" kept branch ""
fi

# 5) 원격 브랜치가 이미 없다 — 레포가 머지 뒤 원격 브랜치를 자동으로 지우는 경우
if setup remote-gone; then
  git -C "$T/remote-gone/main" switch -q feat
  git -C "$T/remote-gone/origin.git" branch -q -D feat
  run4 remote-gone "$T/remote-gone/main"
  check remote-gone "원격 브랜치가 이미 없다: 로컬 브랜치가 지워지고 main 으로 돌아와 fast-forward 된다" \
    "$T/remote-gone/main" gone branch ""
fi

# 6) worktree 에서 fetch 가 실패한다(네트워크 · 권한 프롬프트 거절). base 복귀 줄이 실패해야 세션이
#    멈춘다. 받아 둔 옛 origin/main 에 detach 하면 머지 전 커밋에 detach 한 채 다음 줄로 간다.
#    뒤의 줄은 보지 않는다 — 실제 세션은 실패한 줄에서 멈춘다.
if setup fetch-fails; then
  R="$T/fetch-fails"
  git -C "$R/main" worktree add -q --detach "$R/wt" feat 2>/dev/null
  git -C "$R/main" remote set-url origin "$R/nowhere.git"
  old=$(git -C "$R/main" rev-parse refs/remotes/origin/main)
  run4 fetch-fails "$R/wt"
  r=$(awk -F'\t' '$2 ~ /^if .*git switch/ { print $1 }' "$T/fetch-fails.rc")
  h=$(git -C "$R/wt" rev-parse HEAD)
  if [ -n "$r" ] && [ "$r" != 0 ] && [ "$h" != "$old" ]; then
    ok "worktree 에서 fetch 가 실패한다: base 복귀 줄이 실패하고 옛 origin/main 에 detach 하지 않는다"
  else
    bad "worktree 에서 fetch 가 실패한다: base 복귀 줄의 rc=${r:-없음}, HEAD 가 옛 origin/main 인가=$([ "$h" = "$old" ] && echo 예 || echo 아니오)"
    sed 's/^/      | /' "$T/fetch-fails.log"
  fi
fi

# 7) 원래 체크아웃이 다른 브랜치에 있고 worktree 가 PR 브랜치에 있다 — 병렬 세션에서 흔하다. 원래 체크아웃이
#    main 을 쓰지 않으므로 worktree 의 `git switch main` 은 성공한다. 그래도 worktree 는 detach 해야 원래
#    체크아웃이 나중에 main 으로 옮길 수 있다.
if setup other-work; then
  R="$T/other-work"
  git -C "$R/main" switch -q -c other-work
  git -C "$R/main" worktree add -q "$R/wt" feat 2>/dev/null
  b=$(git -C "$R/main" rev-parse HEAD)
  run4 other-work "$R/wt"
  check other-work "원래 체크아웃이 다른 브랜치에 있다: 두 브랜치가 지워지고 worktree 는 origin/main 에 detach 한다" \
    "$R/wt" gone detached ""
  # 로컬 main 이 머지 전에 남으면 다음 브랜치의 `git log main..HEAD` 가 방금 머지한 커밋을 그 브랜치의 것으로
  # 보여 준다(open-pr · dev-log · trace 의 주입). main 을 쓰는 체크아웃이 없으니 갱신돼야 한다.
  if [ "$(git -C "$R/main" rev-parse refs/heads/main)" = "$(git -C "$R/other" rev-parse HEAD)" ]; then
    ok "원래 체크아웃이 다른 브랜치에 있다: 로컬 main 이 머지된 커밋으로 갱신된다"
  else
    bad "원래 체크아웃이 다른 브랜치에 있다: 로컬 main 이 머지 전 커밋에 남았다"
  fi
  if git -C "$R/main" switch -q main 2>"$T/other-work.switch"; then
    ok "원래 체크아웃이 다른 브랜치에 있다: 그 뒤 원래 체크아웃이 main 으로 옮길 수 있다"
  else
    bad "원래 체크아웃이 다른 브랜치에 있다: 원래 체크아웃이 main 으로 옮기지 못한다 — $(head -1 "$T/other-work.switch")"
  fi
fi

# 8) 원래 체크아웃이 PR 브랜치에 있고 다른 worktree 가 main 을 쓴다 — 원래 체크아웃의 `git switch main` 이
#    실패하는 갈래다. 그때도 detach 해서 PR 브랜치에서 내려와야 두 브랜치를 지울 수 있다.
if setup held; then
  R="$T/held"
  git -C "$R/main" switch -q feat
  git -C "$R/main" worktree add -q "$R/wt" main 2>/dev/null
  run4 held "$R/main"
  check held "다른 worktree 가 main 을 쓴다: 원래 체크아웃이 origin/main 에 detach 하고 두 브랜치가 지워진다" \
    "$R/main" gone detached ""
fi

# 9) 원래 체크아웃의 하위 디렉터리에서 실행한다 — 세션의 작업 디렉터리는 호출 사이에 유지된다. 하위
#    디렉터리에서 `--git-common-dir` 는 상대 경로를 내므로, 절대 경로 형태로 견주지 않으면 원래 체크아웃을
#    worktree 로 판정한다.
if setup subdir; then
  R="$T/subdir"
  git -C "$R/main" switch -q feat
  mkdir -p "$R/main/sub/dir"
  run4 subdir "$R/main/sub/dir"
  check subdir "원래 체크아웃의 하위 디렉터리에서 실행한다: 두 브랜치가 지워지고 main 으로 돌아와 fast-forward 된다" \
    "$R/main" gone branch ""
fi

rm -rf "$T"
exit $fail
