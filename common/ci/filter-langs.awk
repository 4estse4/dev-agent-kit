# gates.yml 에서 설치하지 않은 언어의 흔적을 걷어낸다.
#
# 왜 조건(if:)에 맡기지 않고 지우나 — 조건은 잡을 skip 시킬 뿐 워크플로에 남는다.
# 파이썬 레포의 CI 에 Gradle 잡이 보이면 읽는 사람이 설명을 찾아야 한다.
#
# 걷어내는 자리 다섯:
#   1) 잡 전체        잡 수준 `if: needs.detect.outputs.<lang>`
#   2) 스텝           `- if: needs.detect.outputs.<lang>` 과 그 앞의 주석 묶음
#   3) detect outputs `<lang>: ${{ steps.d.outputs.<lang> }}` 와 그 언어에 딸린 출력(아래 OUTOF)
#   4) detect 탐지문  `find ...` 로 시작해 `echo "<lang>=true"` 가 든 줄까지 한 덩어리.
#                    딸린 출력(gomod)을 내는 줄도 이 덩어리 안에 둔다
#   5) 워크플로 env   해당 언어만 쓰는 변수(아래 ENVOF)
#
# 입력: -v drop="go,jvm"

BEGIN {
  # 어댑터 이름과 CI 의 detect 출력 이름이 다른 것이 하나 있다 — ts 어댑터는
  # package.json 을 보고, CI 는 그 출력을 node 라 부른다. 매핑을 두지 않으면
  # --lang 에서 ts 를 빼도 node 스텝이 남는다.
  CI["ts"] = "node"
  n = split(drop, D, ",")
  for (i = 1; i <= n; i++) { X[D[i]] = 1; if (D[i] in CI) X[CI[D[i]]] = 1 }
  ENVOF["AI_KIT_JAVA_VERSION"] = "jvm"        # 언어 전용 워크플로 변수
  # 언어 이름이 아닌 detect 출력. 그 언어를 빼면 같이 지운다. 안 지우면 go 를 뺀 설치에
  # gomod 출력 줄이 남는다.
  OUTOF["gomod"] = "go"
}

function lang_of(l) { sub(/.*outputs\./, "", l); sub(/[^a-z].*/, "", l); return l }
function emit(l)    { if (injobs) job = job l "\n"; else print l }
function flush_c(   i) { for (i = 1; i <= nc; i++) emit(cbuf[i]); nc = 0 }
function drop_c()   { nc = 0 }
function flush_job() { if (job != "" && !jobdrop) printf "%s", job; job = ""; jobdrop = 0 }

/^jobs:$/ { injobs = 1 }

# 5) 워크플로 env — 한 언어만 쓰는 변수. 다 빠지면 블록째 지운다.
!injobs && /^env:$/ { inenv = 1; envhdr = $0; nenv = 0; next }
!injobs && inenv {
  if ($0 ~ /^  [A-Z_]+:/) {
    k = $0; sub(/^ +/, "", k); sub(/:.*/, "", k)
    if (k in ENVOF && ENVOF[k] in X) next
    ebuf[++nenv] = $0; next
  }
  # 블록 끝 — 남은 항목이 있을 때만 헤더와 함께 되살린다
  if (nenv > 0) { flush_c(); print envhdr; for (i = 1; i <= nenv; i++) print ebuf[i] }
  else { nc = 0 }                      # 앞서 모아둔 설명 주석도 함께 버린다
  inenv = 0
}

injobs && /^  [a-z_-]+:$/ { flush_c(); flush_job() }
injobs && /^    if: needs\.detect\.outputs\.[a-z]+ ==/ { if (lang_of($0) in X) jobdrop = 1 }

# 3) detect 의 outputs
injobs && /^      [a-z]+: \$\{\{ steps\.d\.outputs\.[a-z]+ \}\}$/ {
  l = $0; sub(/^ +/, "", l); sub(/:.*/, "", l)
  if (l in X || (l in OUTOF && OUTOF[l] in X)) next
}

# 4) detect 탐지문 — find 로 시작해 echo "<lang>=true" 로 끝나는 덩어리
/^ +find \./ { infind = 1 }
infind {
  fbuf[++nf] = $0
  if ($0 ~ /echo "[a-z]+=true"/) {
    # 한 줄에 =true 와 =false 가 같이 있다. 탐욕 매칭을 쓰면 뒤쪽(=false)을 잡는다.
    match($0, /echo "[a-z]+=true"/)
    l = substr($0, RSTART + 6, RLENGTH - 12)
    if (!(l in X)) for (i = 1; i <= nf; i++) emit(fbuf[i])
    nf = 0; infind = 0
  }
  next
}

# 최상위 주석은 버퍼에 모은다 — 뒤따르는 블록이 지워지면 함께 지운다.
!injobs && /^#/ { cbuf[++nc] = $0; next }
!injobs && $0 == "" && nc > 0 { cbuf[++nc] = $0; next }
!injobs && nc > 0 { flush_c() }

{
  # 2) 스텝 — 앞선 주석 묶음까지 함께 판정한다
  if ($0 ~ /^      - if: needs\.detect\.outputs\.[a-z]+ ==/) {
    if (lang_of($0) in X) { drop_c(); skip = 1; next }
    flush_c(); skip = 0
  } else if ($0 ~ /^      - /) { flush_c(); skip = 0 }
  else if (!skip && ($0 ~ /^      #/ || ($0 == "" && nc > 0))) { cbuf[++nc] = $0; next }
  else if (skip && $0 ~ /^ {0,5}[^ ]/) { skip = 0 }

  if (skip) next
  emit($0)
}

END { flush_c(); flush_job() }
