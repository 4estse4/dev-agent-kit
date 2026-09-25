#!/usr/bin/env bash
# 킷의 golangci 설정(common/lint/go/.golangci.yml)에서 revive 가 기본 규칙을 실행하는가.
#
# 이 테스트가 있는 이유: 킷은 revive 를 켜고 `exported` 하나만 끄려고, settings.revive.rules 에 그 규칙을
# `disabled: true` 로 두었다. golangci-lint 는 rules 에 규칙이 하나라도 있으면 revive 의 기본 규칙을 쓰지 않고,
# `enable-default-rules: true` 일 때만 유지한다(golangci-lint 의 .golangci.reference.yml). 그래서 revive 는 규칙을
# 하나도 실행하지 않았고, 그것을 알리는 검사가 없었다(이슈 #138). 실제 golangci-lint 로 기본 규칙 위반을
# 찾아내는지는 이 테스트를 더한 PR 에 붙였다. 여기서는 그 설정 규칙대로 설정을 읽는다. 보는 것:
#   · revive 가 linters.enable 에 있다
#   · 기본 규칙이 실행된다 — rules 가 비었거나 enable-default-rules · enable-all-rules 가 true 다
#   · 끄는 규칙은 exported 하나다
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$KIT/common/lint/go/.golangci.yml"
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

[ -f "$CFG" ] || { bad "common/lint/go/.golangci.yml 이 없다"; exit 1; }

# 한 줄에 「enabled defaults off」: revive 가 켜졌나 · 기본 규칙이 실행되나 · 꺼진 규칙(쉼표로)
out=$(python3 - "$CFG" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
lin = c.get("linters") or {}
enabled = "revive" in (lin.get("enable") or [])
s = (lin.get("settings") or {}).get("revive") or {}
rules = s.get("rules") or []
defaults = (not rules) or s.get("enable-default-rules") is True or s.get("enable-all-rules") is True
off = sorted(str(r.get("name")) for r in rules if r.get("disabled") is True)
print("yes" if enabled else "no", "yes" if defaults else "no", ",".join(off) or "-")
PY
) || { bad "설정을 읽지 못했다: $out"; exit 1; }
read -r enabled defaults off <<< "$out"

[ "$enabled" = yes ] && ok "revive 가 linters.enable 에 있다" || bad "revive 가 linters.enable 에 없다"
if [ "$defaults" = yes ]; then ok "revive 의 기본 규칙이 실행된다"
else bad "revive 의 rules 에 규칙이 있는데 enable-default-rules 가 true 가 아니어서 기본 규칙이 실행되지 않는다(꺼진 규칙: $off)"; fi
[ "$off" = exported ] && ok "끄는 규칙은 exported 하나다" || bad "끄는 규칙이 exported 하나가 아니다: $off"

exit $fail
