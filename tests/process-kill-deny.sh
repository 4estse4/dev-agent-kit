#!/usr/bin/env bash
# 프로세스 이름이나 명령줄 글자로 찾아 끝내는 명령(pkill · killall)을 settings 의 deny 가 막는다.
#
# 이 테스트가 있는 이유: 리뷰 에이전트가 스크래치를 정리하며 `pkill -f 'sleep 30'` 을 실행했다(이슈 #179).
# 그 글자는 같은 맥에서 병렬로 일하던 다른 세션의 테스트가 띄운 `sleep 300` 에도 맞는다. 하위 에이전트도
# 세션의 권한 규칙을 따르므로 settings 의 deny 에 둔다. 이 레포는 킷의 settings.json 을 로드하지 않아(이슈 #4)
# 그 일이 일어난 이 레포의 `.claude/settings.json` 에도 둔다.
#
# 보는 것: 깨끗한 레포에 설치한 `.claude/settings.json` 과 이 레포의 `.claude/settings.json` 의 deny 에
# `Bash(pkill*)` · `Bash(killall*)` 가 있다. 규칙을 지우는 회귀만 찾는다 — 규칙이 실제로 막는지는 Claude Code 의
# 매처가 정하므로 이 테스트가 볼 수 없다. 헤드리스 세션으로 확인한 출력은 이 테스트를 더한 PR 의 본문에 있다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }

for f in "$R/.claude/settings.json:설치된 .claude/settings.json" "$KIT/.claude/settings.json:이 레포의 .claude/settings.json"; do
  path="${f%%:*}"; name="${f#*:}"
  python3 - "$path" "$name" <<'PY' || fail=1
import json, sys
path, name = sys.argv[1:3]
deny = ((json.load(open(path, encoding='utf-8')).get('permissions') or {}).get('deny') or [])
missing = [r for r in ('Bash(pkill*)', 'Bash(killall*)') if r not in deny]
if missing:
    print(f"  ✗ {name} 의 deny 에 {' · '.join(missing)} 가 없다")
    sys.exit(1)
print(f"  ✓ {name} 의 deny 에 Bash(pkill*) · Bash(killall*) 가 있다")
PY
done

rm -rf "$T"
exit $fail
