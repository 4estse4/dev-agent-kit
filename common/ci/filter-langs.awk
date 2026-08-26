# gates.yml 에서 설치하지 않은 언어의 스텝·잡을 걷어낸다.
#
# 왜 조건(if:)에 맡기지 않고 지우나 — 조건은 잡을 skip 시킬 뿐 워크플로에 남는다.
# 파이썬 레포의 CI 에 Gradle 잡이 보이면 읽는 사람이 설명을 찾아야 한다.
#
# 입력: -v drop="go,jvm"  (설치하지 않은 언어)
BEGIN { n = split(drop, D, ","); for (i = 1; i <= n; i++) X[D[i]] = 1 }

function lang_of(line,   l) { l = line; sub(/.*outputs\./, "", l); sub(/[^a-z].*/, "", l); return l }
function flush_job() { if (job != "" && !jobdrop) printf "%s", job; job = ""; jobdrop = 0 }

/^jobs:$/ { injobs = 1 }

# 잡 경계 — 이전 잡을 확정하고 새로 연다
injobs && /^  [a-z_-]+:$/ { flush_job() }

# 잡 전체가 한 언어 전용인가 (잡 수준 if:)
injobs && /^    if: needs\.detect\.outputs\.[a-z]+ ==/ { if (lang_of($0) in X) jobdrop = 1 }

# detect 잡이 내보내는 출력 — 소비자가 사라졌으므로 함께 지운다
injobs && /^      [a-z]+: \$\{\{ steps\.d\.outputs\.[a-z]+ \}\}$/ {
  l = $0; sub(/^ +/, "", l); sub(/:.*/, "", l)
  if (l in X) next
}

{
  # 스텝 블록: 지울 언어면 다음 스텝까지 건너뛴다
  if ($0 ~ /^      - if: needs\.detect\.outputs\.[a-z]+ ==/) skip = (lang_of($0) in X)
  else if (skip && ($0 ~ /^      [-#]/ || $0 ~ /^ {0,5}[^ ]/)) skip = 0

  if (skip) next
  if (injobs) job = job $0 "\n"; else print
}

END { flush_job() }
