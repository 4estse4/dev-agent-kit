#!/usr/bin/env bash
# 설치된 킷이 킷 클론보다 낡았을 때 SessionStart 훅(`kit_freshness.sh`)이 그렇다고 한 줄로 알리는가.
#
# 이 테스트가 있는 이유: 훅은 설치기가 대상 레포의 로컬 git config 에 적은 킷 경로(`kit.path`)와
# `.kit/install-manifest` 의 `kit_rev` 로 판정한다. 설정 키 이름이 둘 중 한쪽에서만 바뀌면 훅은 알 수 없는
# 경우로 보고 아무것도 출력하지 않는다 — 실패가 아니라 침묵이라 쓰는 사람이 알아챌 계기가 없다. 킷 이름을
# 바꾸면서(이슈 #57) 알림 문구의 앞머리가 바뀌었을 때 콜론 뒤의 공백이 빠졌는데 이 훅을 보는 테스트가 없었다.
#
# 훅을 직접 설정해 부르지 않고 설치기를 거친다(`install.sh <레포>` 가 `kit.path` 와 `kit_rev` 를 적는다).
# CI 의 체크아웃은 커밋 하나뿐이라, 킷 파일을 복사한 사본에 커밋을 쌓아 킷 클론으로 쓴다. 보는 것:
#   · 설치 직후(킷 클론과 같은 리비전)에는 아무것도 출력하지 않는다
#   · 킷 클론에 커밋이 둘 더 생기면 「dev-agent-kit: 설치된 킷이 2개 커밋 낡았습니다 — …」 한 줄을 출력한다
#   · 기록된 리비전이 킷 클론에 없으면 「dev-agent-kit: 설치된 킷 리비전 … 을 로컬 킷에서 찾을 수 없습니다」
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
K="$T/kit"; R="$T/app"
mkdir -p "$K"
tar -C "$KIT" --exclude=.git -cf - . | tar -C "$K" -xf -
git init -q -b main "$K"; git -C "$K" config user.email t@example.com; git -C "$K" config user.name T
git -C "$K" add -A; git -C "$K" commit -qm v1 --no-verify
git init -q -b main "$R"; git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$K/install.sh" "$R" --hooks --agent > "$T/install.log" 2>&1 || { bad "설치가 실패했다"; tail -5 "$T/install.log"; exit 1; }

hook() { CLAUDE_PROJECT_DIR="$R" bash "$R/.claude/hooks/kit_freshness.sh" 2>&1; }

out=$(hook)
if [ -z "$out" ]; then ok "설치 직후에는 아무것도 출력하지 않는다"
else bad "설치 직후인데 출력했다: $out"; fi

v1=$(git -C "$K" rev-parse --short HEAD)
git -C "$K" commit -q --allow-empty -m v2; git -C "$K" commit -q --allow-empty -m v3
v3=$(git -C "$K" rev-parse --short HEAD)
out=$(hook)
want="dev-agent-kit: 설치된 킷이 2개 커밋 낡았습니다 — $v1 ("
if [ "${out#"$want"}" != "$out" ] && printf '%s' "$out" | grep -qF "→ $v3 (" && printf '%s' "$out" | grep -qF "확인: $K/install.sh . --dry-run"; then
  ok "킷 클론이 두 커밋 앞서면 설치본이 낡았다고 알린다"
else bad "킷 클론이 두 커밋 앞섰는데 「${want}…→ $v3 (…」로 알리지 않았다: [$out]"; fi

sed -i.bak 's/^kit_rev=.*/kit_rev=0000000/' "$R/.kit/install-manifest"
out=$(hook)
want="dev-agent-kit: 설치된 킷 리비전 0000000 을 로컬 킷에서 찾을 수 없습니다 (현재 $v3 ("
if [ "${out#"$want"}" != "$out" ]; then ok "기록된 리비전이 킷 클론에 없으면 그렇다고 알린다"
else bad "기록된 리비전이 킷 클론에 없는데 「${want}…」로 알리지 않았다: [$out]"; fi

exit $fail
