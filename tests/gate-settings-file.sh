#!/usr/bin/env bash
# 게이트 설정 값을 커밋된 `.kit/gate.conf` 에서만 읽는가 — 환경 변수로는 검사가 줄지 않는가.
#
# 이 테스트가 있는 이유: 게이트는 테스트 · 태스크 플래그(`KIT_GO_TEST_FLAGS` · `KIT_PYTEST_FLAGS` · `KIT_GRADLE_TASKS`)와
# 모듈을 찾을 때 건너뛸 디렉터리(`KIT_PRUNE_DIRS`)를 환경에서 읽었고, 훅은 부를 킷 디렉터리를 `KIT_DIR` 로 받았다. 세션이 명령
# 앞에 `KIT_PRUNE_DIRS=backend` 한 낱말을 붙이면 실패해야 할 게이트가 「검사 대상 없음」으로 통과했고, 그 값은 어디에도 남지
# 않았다(이슈 #212). 그래서 값은 커밋된 파일에서만 읽고, 그 파일에 커밋에 안 들어간 변경이 있으면 훅이 실패한다.
# 보는 것:
#   · 환경 변수 넷이 게이트가 실행하는 테스트 · 태스크와 찾는 모듈을 바꾸지 않는다
#   · `.kit/gate.conf` 의 값은 적용된다(공백이 든 값 포함)
#   · 값은 공백에서만 나눈다 — 공백뿐인 값은 기본값이고, 와일드카드는 파일 이름으로 펼치지 않는다(`-run` 정규식 ·
#     gradle 태스크 · `find -name` 패턴). `KIT_PRUNE_DIRS` 의 이름과 패턴(`.` · `.*` · `?` · `*` · `build*`)은 시작점과
#     마커 파일을 건너뛰지 않는다. 모듈을 찾다 읽지 못한 디렉터리는 게이트 출력에 알린다
#   · `.kit/gate.conf` 에 커밋에 안 들어간 변경이 있으면 커밋 훅과 푸시 훅이 실패한다 — 작업 트리만 고침 · 인덱스에서 뺌 ·
#     (푸시 훅) 스테이지만 하고 커밋하지 않음 · 커밋한 적 없음. 커밋에 넣으려고 스테이지한 변경(커밋 훅)과 깨끗한 상태는 그
#     이유로 막지 않는다
#   · 재설치가 `.kit/gate.conf` 를 남기고(미리보기도 지운다고 예고하지 않는다), 설치기도 대상 레포의 그 파일로 건너뛸
#     디렉터리를 정한다
#   · 훅은 `KIT_DIR` 을 받지 않고 자기 위치에서 킷을 찾는다
#
# 테스트 · 태스크를 실제로 실행하지 않는다. 받은 인자를 적는 가짜 `go` · `pytest` · `gradlew` 로 무엇이 실행됐는지 본다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fail=1; }
show() { printf '%s\n' "$1" | sed 's/^/      /' | head -12; }
ZERO=0000000000000000000000000000000000000000

newrepo() { # $1=경로 $2=--lang 값 — 킷을 설치하고 커밋해 둔다(훅이 보는 .kit/ 가 커밋에 들어 있게)
  git init -q -b main "$1"
  git -C "$1" config user.email t@example.com; git -C "$1" config user.name T
  git -C "$1" commit -q --allow-empty -m init
  bash "$KIT/install.sh" "$1" --lang "$2" > "$T/install.log" 2>&1 \
    || { bad "설치가 실패했다:"; show "$(tail -5 "$T/install.log")"; exit 1; }
  git -C "$1" add -A; git -C "$1" commit -q --no-verify -m kit
}
fake() { # $1=만들 경로 $2=로그에 적을 이름
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG"\n' "$2" > "$1"; chmod +x "$1"
}

echo "── 게이트가 실행하는 것"
R="$T/r"; newrepo "$R" go,py,jvm
# java 는 jvm 어댑터가 있는지만 본다 — 머신에 없어도 gradlew 까지 가게 둔다
F="$T/fakebin"; fake "$F/go" go; fake "$F/java" java
mkdir -p "$R/svc-go" "$R/svc-py" "$R/svc-jvm"
printf 'module example.com/m\n\ngo 1.25\n' > "$R/svc-go/go.mod"
printf '[project]\nname = "p"\nversion = "0"\n' > "$R/svc-py/pyproject.toml"
fake "$R/svc-py/.venv/bin/pytest" pytest
: > "$R/svc-jvm/settings.gradle"; fake "$R/svc-jvm/gradlew" gradlew

gate() { # [변수=값 …] — 게이트를 --all 로 실행한다. 가짜 도구가 받은 인자가 $log 에 남는다
  : > "$T/log"
  out=$(cd "$R" && env "$@" FAKE_LOG="$T/log" PATH="$F:$PATH" bash .kit/gate/gate.sh --all 2>&1); rc=$?
  log=$(cat "$T/log")
}
ran() { printf '%s\n' "$log" | grep -qxF -- "$1"; }

gate KIT_GO_TEST_FLAGS='-run ^$' KIT_PYTEST_FLAGS='-k nothing' KIT_GRADLE_TASKS=help
ran 'go test ./...' && ok "환경 변수 KIT_GO_TEST_FLAGS 가 go test 에 붙지 않는다" \
  || { bad "환경 변수 KIT_GO_TEST_FLAGS 가 go test 에 붙었다:"; show "$log"; }
ran 'pytest -q' && ok "환경 변수 KIT_PYTEST_FLAGS 가 pytest 에 붙지 않는다" \
  || { bad "환경 변수 KIT_PYTEST_FLAGS 가 pytest 에 붙었다:"; show "$log"; }
ran 'gradlew --no-daemon --console=plain check' && ok "환경 변수 KIT_GRADLE_TASKS 가 gradle 태스크를 바꾸지 않는다" \
  || { bad "환경 변수 KIT_GRADLE_TASKS 가 gradle 태스크를 바꿨다:"; show "$log"; }
gate KIT_PRUNE_DIRS=svc-py
ran 'pytest -q' && ok "환경 변수 KIT_PRUNE_DIRS 가 모듈을 검사에서 빼지 않는다" \
  || { bad "환경 변수 KIT_PRUNE_DIRS 가 svc-py 를 검사에서 뺐다:"; show "$out"; }

printf '# 게이트 설정\nKIT_GO_TEST_FLAGS=-run ^$\nKIT_PYTEST_FLAGS=-k nothing\nKIT_GRADLE_TASKS=help\n' > "$R/.kit/gate.conf"
gate
ran 'go test -run ^$ ./...' && ok ".kit/gate.conf 의 KIT_GO_TEST_FLAGS 가 go test 에 붙는다" \
  || { bad ".kit/gate.conf 의 KIT_GO_TEST_FLAGS 가 go test 에 붙어야 한다:"; show "$log"; }
ran 'pytest -q -k nothing' && ok ".kit/gate.conf 의 KIT_PYTEST_FLAGS 가 pytest 에 붙는다" \
  || { bad ".kit/gate.conf 의 KIT_PYTEST_FLAGS 가 pytest 에 붙어야 한다:"; show "$log"; }
ran 'gradlew --no-daemon --console=plain help' && ok ".kit/gate.conf 의 KIT_GRADLE_TASKS 가 gradle 태스크가 된다" \
  || { bad ".kit/gate.conf 의 KIT_GRADLE_TASKS 가 gradle 태스크가 되어야 한다:"; show "$log"; }
printf 'KIT_PRUNE_DIRS=.git node_modules .venv svc-py\n' >> "$R/.kit/gate.conf"
gate
printf '%s\n' "$log" | grep -q '^pytest' && { bad ".kit/gate.conf 의 KIT_PRUNE_DIRS 가 svc-py 를 빼야 한다:"; show "$log"; } \
  || ok ".kit/gate.conf 의 KIT_PRUNE_DIRS 가 모듈을 검사에서 뺀다"

echo "── .kit/gate.conf 의 값을 읽는 법"
# 공백뿐인 값은 값이 없는 것이다. 공백 하나가 남은 줄은 diff 에서 빈 값과 구분되지 않는데, 그대로 읽으면 건너뛸 목록이
# 비어 모듈 탐색이 통째로 꺼지고 gradle 태스크가 빠진다
printf 'KIT_PRUNE_DIRS= \nKIT_GRADLE_TASKS= \n' > "$R/.kit/gate.conf"
gate
ran 'pytest -q' && ok "공백뿐인 KIT_PRUNE_DIRS 는 기본 목록으로 읽어 모듈을 찾는다" \
  || { bad "공백뿐인 KIT_PRUNE_DIRS 로 모듈을 찾지 못했다:"; show "$out"; }
ran 'gradlew --no-daemon --console=plain check' && ok "공백뿐인 KIT_GRADLE_TASKS 는 check 를 실행한다" \
  || { bad "공백뿐인 KIT_GRADLE_TASKS 가 check 를 없앴다:"; show "$log"; }
printf 'KIT_PRUNE_DIRS=.git node_modules .venv .\n' > "$R/.kit/gate.conf"
gate
ran 'pytest -q' && ok "KIT_PRUNE_DIRS 의 . 은 모듈 탐색을 통째로 끄지 않는다" \
  || { bad "KIT_PRUNE_DIRS 의 . 이 모듈 탐색을 껐다:"; show "$out"; }
# 패턴도 find 의 시작점(.)에 맞으면 탐색이 통째로 꺼진다. .* 는 숨김 디렉터리만 건너뛰어야 한다
mkdir -p "$R/.hidden"; printf '[project]\nname = "h"\nversion = "0"\n' > "$R/.hidden/pyproject.toml"
fake "$R/.hidden/.venv/bin/pytest" hidpytest
printf 'KIT_PRUNE_DIRS=.*\n' > "$R/.kit/gate.conf"
gate
if ran 'go test ./...' && ! printf '%s\n' "$log" | grep -q '^hidpytest'; then
  ok "KIT_PRUNE_DIRS 의 .* 는 숨김 디렉터리만 건너뛰고 모듈 탐색을 끄지 않는다"
else bad "KIT_PRUNE_DIRS 의 .* 는 숨김 디렉터리만 건너뛰어야 한다:"; show "$log"; fi
rm -rf "$R/.hidden"
printf 'KIT_PRUNE_DIRS=?\n' > "$R/.kit/gate.conf"
gate
ran 'go test ./...' && ok "KIT_PRUNE_DIRS 의 ? 는 모듈 탐색을 통째로 끄지 않는다" \
  || { bad "KIT_PRUNE_DIRS 의 ? 가 모듈 탐색을 껐다:"; show "$out"; }
# 건너뛰는 것은 디렉터리다. 패턴이 마커 파일 이름에 맞아도 그 파일은 찾는다. * 는 모든 하위 디렉터리를 건너뛰므로
# go test 는 루트 모듈에서만 실행된다. 게이트는 모듈 디렉터리에서 어댑터를 실행하므로, 가짜 go 가 실행된 디렉터리
# 이름(루트는 r)을 함께 적게 해 그것을 본다
printf 'module example.com/root\n\ngo 1.25\n' > "$R/go.mod"
printf '#!/usr/bin/env bash\necho "go@${PWD##*/} $*" >> "$FAKE_LOG"\n' > "$F/go"
printf 'KIT_PRUNE_DIRS=*\n' > "$R/.kit/gate.conf"
gate
if ran 'go@r test ./...' && ! printf '%s\n' "$log" | grep -q '^go@svc-go '; then
  ok "KIT_PRUNE_DIRS 의 * 는 하위 디렉터리만 건너뛰고 루트 모듈은 찾는다"
else bad "KIT_PRUNE_DIRS 의 * 는 루트 모듈에서만 go test 를 실행해야 한다:"; show "$log"; fi
rm -f "$R/go.mod"; fake "$F/go" go
# build 디렉터리를 건너뛰려는 build* 가 build.gradle.kts 까지 건너뛰면 그 모듈이 검사에서 빠진다
mkdir -p "$R/svc-kts"; : > "$R/svc-kts/build.gradle.kts"; fake "$R/svc-kts/gradlew" ktsgradlew
printf 'KIT_PRUNE_DIRS=.git node_modules .venv build*\n' > "$R/.kit/gate.conf"
gate
ran 'ktsgradlew --no-daemon --console=plain check' && ok "KIT_PRUNE_DIRS 의 build* 는 build.gradle.kts 를 건너뛰지 않는다" \
  || { bad "KIT_PRUNE_DIRS 의 build* 가 build.gradle.kts 의 모듈을 검사에서 뺐다:"; show "$log"; }
rm -rf "$R/svc-kts"
# 값은 공백에서만 나눈다. 와일드카드를 파일 이름으로 펼치면 -run 정규식 · find -name 패턴이 다른 것이 된다.
# 각 모듈 디렉터리에는 그 패턴에 맞는 파일이 있다(go.mod · pyproject.toml · settings.gradle)
printf 'KIT_GO_TEST_FLAGS=-run go.*\nKIT_PYTEST_FLAGS=-k py*\nKIT_GRADLE_TASKS=settings*\n' > "$R/.kit/gate.conf"
gate
ran 'go test -run go.* ./...' && ok "KIT_GO_TEST_FLAGS 의 와일드카드를 파일 이름으로 펼치지 않는다" \
  || { bad "KIT_GO_TEST_FLAGS 의 와일드카드가 펼쳐졌다:"; show "$log"; }
ran 'pytest -q -k py*' && ok "KIT_PYTEST_FLAGS 의 와일드카드를 파일 이름으로 펼치지 않는다" \
  || { bad "KIT_PYTEST_FLAGS 의 와일드카드가 펼쳐졌다:"; show "$log"; }
ran 'gradlew --no-daemon --console=plain settings*' && ok "KIT_GRADLE_TASKS 의 와일드카드를 파일 이름으로 펼치지 않는다" \
  || { bad "KIT_GRADLE_TASKS 의 와일드카드가 펼쳐졌다:"; show "$log"; }
# find -name 에 전달할 패턴. 루트의 vend.txt 로 펼쳐지면 lib/vend-py 를 건너뛰지 못한다
: > "$R/vend.txt"; mkdir -p "$R/lib/vend-py"; printf '[project]\nname = "v"\nversion = "0"\n' > "$R/lib/vend-py/pyproject.toml"
fake "$R/lib/vend-py/.venv/bin/pytest" vendpytest
printf 'KIT_PRUNE_DIRS=.git node_modules .venv vend*\n' > "$R/.kit/gate.conf"
gate
printf '%s\n' "$log" | grep -q '^vendpytest' && { bad "KIT_PRUNE_DIRS 의 vend* 가 파일 이름으로 펼쳐져 lib/vend-py 를 건너뛰지 못했다:"; show "$log"; } \
  || ok "KIT_PRUNE_DIRS 의 패턴을 파일 이름으로 펼치지 않고 find -name 에 전달한다"
rm -rf "$R/vend.txt" "$R/lib"
# 읽지 못한 디렉터리 — 게이트는 실패하지 않지만 그 안의 모듈은 검사되지 않았으므로 알린다
rm -f "$R/.kit/gate.conf"; mkdir -p "$R/locked/svc"; : > "$R/locked/svc/go.mod"; chmod 000 "$R/locked"
if [ -r "$R/locked" ]; then
  echo "  - 건너뜀: 이 사용자는 권한을 지운 디렉터리도 읽는다(root) — 읽지 못한 디렉터리 경우를 만들 수 없다"
else
  gate
  if printf '%s\n' "$out" | grep -q '읽지 못한 디렉터리' && printf '%s\n' "$out" | grep -q 'locked' && ran 'pytest -q'; then
    ok "모듈을 찾다 읽지 못한 디렉터리를 게이트 출력에 알리고 나머지 모듈은 검사한다"
  else bad "모듈을 찾다 읽지 못한 디렉터리를 게이트 출력에 알려야 한다:"; show "$out"; fi
fi
chmod 755 "$R/locked"; rm -rf "$R/locked"

echo "── 커밋에 안 들어간 .kit/gate.conf"
H="$T/h"; newrepo "$H" py
C="$H/.kit/gate.conf"
printf 'KIT_PYTEST_FLAGS=-x\n' > "$C"; git -C "$H" add -A; git -C "$H" commit -q --no-verify -m conf
git -C "$H" switch -qc feature
echo x > "$H/README"; git -C "$H" add README
pc() { out=$(cd "$H" && bash .kit/git-hooks/pre-commit 2>&1); rc=$?; }
pp() { # 지금 HEAD 를 새 원격 브랜치로 푸시하는 입력을 준다
  local head; head=$(git -C "$H" rev-parse HEAD)
  out=$(cd "$H" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$head" "$ZERO" | bash .kit/git-hooks/pre-push origin x 2>&1); rc=$?
}
conf_blocked() { [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'gate\.conf'; }

pc; conf_blocked && { bad "커밋 훅이 깨끗한 .kit/gate.conf 로 막았다:"; show "$out"; } \
  || ok "커밋 훅은 깨끗한 .kit/gate.conf 로 막지 않는다"
printf 'KIT_PYTEST_FLAGS=-k nothing\n' > "$C"
pc; conf_blocked && ok "작업 트리만 고친 .kit/gate.conf 가 있으면 커밋 훅이 실패한다" \
  || { bad "작업 트리만 고친 .kit/gate.conf 가 있으면 커밋 훅이 실패해야 한다(rc=$rc):"; show "$out"; }
git -C "$H" add .kit/gate.conf
pc; conf_blocked && { bad "커밋 훅이 커밋에 넣으려고 스테이지한 .kit/gate.conf 로 막았다:"; show "$out"; } \
  || ok "커밋 훅은 커밋에 넣으려고 스테이지한 .kit/gate.conf 로 막지 않는다"
git -C "$H" rm -q --cached .kit/gate.conf
pc; conf_blocked && ok "인덱스에서 뺀 .kit/gate.conf 가 작업 트리에 남으면 커밋 훅이 실패한다" \
  || { bad "인덱스에서 뺀 .kit/gate.conf 가 작업 트리에 남으면 커밋 훅이 실패해야 한다(rc=$rc):"; show "$out"; }

git -C "$H" add .kit/gate.conf; git -C "$H" commit -q --no-verify -m change
pp; conf_blocked && { bad "푸시 훅이 깨끗한 .kit/gate.conf 로 막았다:"; show "$out"; } \
  || ok "푸시 훅은 깨끗한 .kit/gate.conf 로 막지 않는다"
printf 'KIT_PYTEST_FLAGS=-q\n' > "$C"
pp; conf_blocked && ok "작업 트리만 고친 .kit/gate.conf 가 있으면 푸시 훅이 실패한다" \
  || { bad "작업 트리만 고친 .kit/gate.conf 가 있으면 푸시 훅이 실패해야 한다(rc=$rc):"; show "$out"; }
git -C "$H" add .kit/gate.conf
pp; conf_blocked && ok "스테이지만 하고 커밋하지 않은 .kit/gate.conf 가 있으면 푸시 훅이 실패한다" \
  || { bad "스테이지만 하고 커밋하지 않은 .kit/gate.conf 가 있으면 푸시 훅이 실패해야 한다(rc=$rc):"; show "$out"; }
git -C "$H" rm -q --cached .kit/gate.conf
pp; conf_blocked && ok "인덱스에서 뺀 .kit/gate.conf 가 작업 트리에 남으면 푸시 훅이 실패한다" \
  || { bad "인덱스에서 뺀 .kit/gate.conf 가 작업 트리에 남으면 푸시 훅이 실패해야 한다(rc=$rc):"; show "$out"; }
# 위 경우는 HEAD 에 그 파일이 있어 HEAD 와 견주면 드러난다. 한 번도 커밋하지 않은 파일은 HEAD 에도 인덱스에도 없다
git -C "$H" commit -q --no-verify -m 'drop conf'
pp; conf_blocked && ok "커밋한 적 없는 .kit/gate.conf 가 작업 트리에 있으면 푸시 훅이 실패한다" \
  || { bad "커밋한 적 없는 .kit/gate.conf 가 작업 트리에 있으면 푸시 훅이 실패해야 한다(rc=$rc):"; show "$out"; }

echo "── 재설치"
git -C "$H" add .kit/gate.conf
printf 'KIT_PYTEST_FLAGS=-x\nKIT_PRUNE_DIRS=.git node_modules .venv legacy\n' > "$C"
mkdir -p "$H/legacy"; printf '[project]\nname = "l"\nversion = "0"\n' > "$H/legacy/pyproject.toml"
git -C "$H" add -A; git -C "$H" commit -q --no-verify -m legacy
before=$(cat "$C")
dry=$(bash "$KIT/install.sh" "$H" --lang py --dry-run 2>&1)
printf '%s\n' "$dry" | grep -qxF '  - .kit/gate.conf' && { bad "재설치 미리보기가 .kit/gate.conf 를 지운다고 예고했다:"; show "$dry"; } \
  || ok "재설치 미리보기가 .kit/gate.conf 를 지운다고 예고하지 않는다"
bash "$KIT/install.sh" "$H" --lang py > "$T/reinstall.log" 2>&1 || { bad "재설치가 실패했다:"; show "$(tail -5 "$T/reinstall.log")"; }
[ -f "$C" ] && [ "$(cat "$C")" = "$before" ] && ok "재설치가 .kit/gate.conf 를 그대로 남긴다" \
  || { bad "재설치가 .kit/gate.conf 를 남겨야 한다:"; show "$(cat "$C" 2>&1)"; }
[ -e "$H/legacy/ruff.toml" ] && bad "설치기가 .kit/gate.conf 의 KIT_PRUNE_DIRS 로 뺀 legacy/ 에 ruff.toml 을 놓았다" \
  || ok "설치기가 대상 레포의 .kit/gate.conf 로 건너뛸 디렉터리를 정한다"

echo "── 훅이 부르는 킷"
K="$T/k"; newrepo "$K" py
git -C "$K" switch -qc feature
mkdir -p "$K/web"; printf '{"name":"w"}\n' > "$K/web/package.json"; git -C "$K" add web
mkdir -p "$T/fakekit/gate"; printf 'exit 0\n' > "$T/fakekit/gate/secrets.sh"; printf 'exit 0\n' > "$T/fakekit/gate/gate.sh"
# ts 어댑터를 설치하지 않은 레포의 package.json — 킷의 게이트라면 어댑터 없는 검사로 실패한다
out=$(cd "$K" && KIT_DIR="$T/fakekit" bash .kit/git-hooks/pre-commit 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'ts(어댑터 없음)' \
  && ok "커밋 훅이 KIT_DIR 을 받지 않고 자기 위치의 킷으로 게이트를 실행한다" \
  || { bad "커밋 훅이 KIT_DIR 이 가리킨 디렉터리의 게이트를 실행했다(rc=$rc):"; show "$out"; }
git -C "$K" commit -q --no-verify -m web
head=$(git -C "$K" rev-parse HEAD)
out=$(cd "$K" && printf 'refs/heads/feature %s refs/heads/feature %s\n' "$head" "$ZERO" | KIT_DIR="$T/fakekit" bash .kit/git-hooks/pre-push origin x 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'ts(어댑터 없음)' \
  && ok "푸시 훅이 KIT_DIR 을 받지 않고 자기 위치의 킷으로 게이트를 실행한다" \
  || { bad "푸시 훅이 KIT_DIR 이 가리킨 디렉터리의 게이트를 실행했다(rc=$rc):"; show "$out"; }

[ "$fail" = 0 ] && echo "  ✓ 게이트 설정은 커밋된 .kit/gate.conf 에서만 읽힌다"
exit $fail
