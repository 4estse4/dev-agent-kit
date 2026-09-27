#!/usr/bin/env bash
# `install.sh --protect` 가 부르는 브랜치 보호 스크립트가 봇 설정(`.claude/bot.json`)이 있을 때만 사람의
# Approve 를 요구하는가.
#
# 봇 설정이 있으면 PR 작성자가 봇이라 사람이 Approve 할 수 있고, 머지 승인은 그 Approve 다. 봇 설정이
# 없으면 PR 작성자가 사람 자신이라 자기 PR 을 Approve 할 수 없어, 승인을 요구하면 모든 머지가 막힌다.
#
# **네트워크를 안 쓴다.** PATH 앞에 둔 가짜 `gh` 가 레포 이름을 돌려주고, 보호 설정으로 보낸 본문을
# 파일에 적는다. 스크립트는 `install.sh` 처럼 대상 레포 안에서 부른다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/bot/.claude" "$T/plain"
git -C "$T/bot" init -q
git -C "$T/plain" init -q
printf '{"app_id": 1, "app": "kit-bot"}\n' > "$T/bot/.claude/bot.json"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") echo o/r ;;
  "api -X") cat > "$STUB_BODY" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
fail=0

# protect <디렉터리> — 보호 설정을 부르고 보낸 본문의 승인 조건을 한 줄로 낸다
protect() {
  : > "$T/body.json"
  ( cd "$1" && PATH="$T/bin:$PATH" STUB_BODY="$T/body.json" bash "$KIT/common/ci/protect-branch.sh" ) >/dev/null 2>&1
  python3 -c 'import json,sys; r = json.load(open(sys.argv[1]))["required_pull_request_reviews"]
print(r.get("required_approving_review_count"), r.get("dismiss_stale_reviews"), r.get("require_last_push_approval"))' \
    "$T/body.json" 2>/dev/null
}
check() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1 ($3)"; else echo "  ✗ $1 — 기대 「$2」, 실제 「$3」"; fail=1; fi
}

check "봇 설정이 있으면 승인 1 · 새 커밋이 오면 이전 승인 무효 · 마지막 푸시는 다른 사람이 승인" \
  "1 True True" "$(protect "$T/bot")"
check "봇 설정이 없으면 승인을 요구하지 않는다" "0 True False" "$(protect "$T/plain")"
mkdir -p "$T/bot/sub"
check "레포 하위 디렉터리에서 불러도 봇 설정을 찾는다" "1 True True" "$(protect "$T/bot/sub")"

[ "$fail" = 0 ] && echo "  ✓ 봇 설정이 있을 때만 브랜치 보호가 사람의 Approve 를 요구한다"
exit "$fail"
