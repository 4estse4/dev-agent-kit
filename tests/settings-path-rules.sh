#!/usr/bin/env bash
# settings 의 파일 경로 규칙은 Read · Edit 로만 쓴다.
#
# 이 테스트가 있는 이유: 설치되는 settings.json 의 deny 에 `Write(//**/kit-bot/**)` 가 있었다(이슈 #172).
# Claude Code 는 파일 경로 규칙을 Read · Edit 로만 보므로 그 규칙은 아무것도 막지 않고, 세션을 열 때마다
# 경고만 낸다. 문서 원문과 확인한 것은 common/docs/verification-stages.md 6.2 에 있다. 그 규칙이 막는다고
# 믿으면 막는 것이 없는 자리가 생긴다. Write 도구는 같은 경로의 `Edit(...)` 규칙이 막는다.
#
# 보는 것: 깨끗한 레포에 설치한 `.claude/settings.json` 과 이 레포의 `.claude/settings.json` 의 allow · ask ·
# deny 에 `Write(…)` · `NotebookEdit(…)` · `Glob(…)` · `MultiEdit(…)` 경로 규칙이 없다. 괄호 없이 도구 이름만 쓴
# 규칙은 경로 규칙이 아니라서 보지 않는다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

T=$(mktemp -d); R="$T/repo"; mkdir -p "$R"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com; git -C "$R" config user.name T
git -C "$R" commit -q --allow-empty -m init
bash "$KIT/install.sh" "$R" --agent > "$T/install.log" 2>&1 || { echo "  ✗ 설치가 실패했다:"; tail -5 "$T/install.log" | sed 's/^/      /'; exit 1; }
[ -f "$R/.claude/settings.json" ] || { echo "  ✗ 설치 뒤에 .claude/settings.json 이 없다 — 설치 경로가 바뀌었나"; exit 1; }

for f in "$R/.claude/settings.json:설치된 .claude/settings.json" "$KIT/.claude/settings.json:이 레포의 .claude/settings.json"; do
  path="${f%%:*}"; name="${f#*:}"
  python3 - "$path" "$name" <<'PY' || fail=1
import json, re, sys
path, name = sys.argv[1:3]
perms = json.load(open(path, encoding='utf-8')).get('permissions') or {}
bad = [(k, r) for k in ('allow', 'ask', 'deny') for r in perms.get(k) or []
       if re.match(r'(Write|NotebookEdit|Glob|MultiEdit)\(', r)]
if bad:
    for k, r in bad:
        print(f"  ✗ {name} 의 {k} 에 쓰이지 않는 경로 규칙이 있다: {r} — Read(…) · Edit(…) 로 쓴다")
    sys.exit(1)
print(f"  ✓ {name} 의 경로 규칙이 Read · Edit 로만 쓰였다")
PY
done

rm -rf "$T"
exit $fail
