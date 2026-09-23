#!/bin/sh
input=$(cat)

# 구분자 2단계: 그룹 사이는 SEP, 그룹 안은 SUB
SEP=" │ "
SUB=" · "

# --- Core fields ---
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')
version=$(echo "$input" | jq -r '.version // empty')

# --- Context window ---
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# --- Effort / thinking / fast mode ---
# effort.level: low|medium|high|xhigh|max. 모델이 effort 미지원이면 필드 자체가 없음.
effort=$(echo "$input" | jq -r '.effort.level // empty')
# 주의: jq 의 // 는 false 도 걸러내므로 불리언은 명시 비교로 뽑는다.
thinking_off=$(echo "$input" | jq -r 'if .thinking.enabled == false then "1" else "" end')
fast_mode=$(echo "$input" | jq -r 'if .fast_mode == true then "1" else "" end')

# --- Rate limits ---
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# --- Vim mode ---
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')

# --- Agent ---
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

# --- Worktree ---
# .worktree.branch 는 --worktree 세션에서만, .workspace.git_worktree 는
# git worktree add 로 만든 모든 트리에서 채워진다.
worktree_branch=$(echo "$input" | jq -r '.worktree.branch // .workspace.git_worktree // empty')

# --- Pull request / merge request ---
pr_num=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')
pr_kind=$(echo "$input" | jq -r '.pr.kind // empty')

# --- Output style ---
output_style=$(echo "$input" | jq -r '.output_style.name // empty')

# --- Reset countdown helper ---
# 괄호 안은 항상 "남은 시간" 하나의 의미로 통일한다.
#   < 1h   -> 43m
#   < 24h  -> 1h 43m
#   >= 24h -> 4d 9h 23m
eta() {
  now=$(date +%s)
  diff=$(( $1 - now ))
  if [ "$diff" -le 0 ]; then
    printf "now"
    return
  fi

  if [ "$diff" -lt 3600 ]; then
    printf "%dm" "$(( diff / 60 ))"
  elif [ "$diff" -lt 86400 ]; then
    printf "%dh %02dm" "$(( diff / 3600 ))" "$(( (diff % 3600) / 60 ))"
  else
    printf "%dd %dh %02dm" \
      "$(( diff / 86400 ))" \
      "$(( (diff % 86400) / 3600 ))" \
      "$(( (diff % 3600) / 60 ))"
  fi
}

# --- Git info (from cwd) ---
git_info=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=$(git -C "$cwd" -c core.quotePath=false --no-optional-locks status --porcelain 2>/dev/null)
    if [ -n "$dirty" ]; then
      git_info="${branch}*"
    else
      git_info="${branch}"
    fi
  fi
fi

# --- Dir ---
if [ -n "$cwd" ]; then
  dir=$(basename "$cwd")
else
  dir=$(basename "$(pwd)")
fi

# --- Build context bar ---
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  filled=$(( used_int / 5 ))
  empty_blocks=$(( 20 - filled ))
  bar=""
  i=0
  while [ $i -lt $filled ]; do
    bar="${bar}█"
    i=$(( i + 1 ))
  done
  i=0
  while [ $i -lt $empty_blocks ]; do
    bar="${bar}░"
    i=$(( i + 1 ))
  done
  ctx_str="[${bar}] ${used_int}%"
else
  ctx_str="[░░░░░░░░░░░░░░░░░░░░] -"
fi

# --- Assemble ---
# 그룹 순서: 세션 │ git │ 모델 │ ctx │ 리밋 │ 모드 │ 꼬리

parts=""
add_group() {  # 비어 있지 않은 그룹만 SEP 으로 잇는다
  [ -z "$1" ] && return
  if [ -z "$parts" ]; then
    parts="$1"
  else
    parts="${parts}${SEP}$1"
  fi
}

# 1) 세션: 어디서 · 무엇을
g="${dir}"
[ -n "$session_name" ] && g="${g}${SUB}${session_name}"
add_group "$g"

# 2) git: 브랜치 · worktree · PR/MR
g=""
[ -n "$git_info" ] && g="git:${git_info}"
if [ -n "$worktree_branch" ]; then
  [ -n "$g" ] && g="${g}${SUB}"
  g="${g}wt:${worktree_branch}"
fi
if [ -n "$pr_num" ]; then
  if [ "$pr_kind" = "mr" ]; then
    pr_label="mr"
  else
    pr_label="pr"
  fi
  [ -n "$g" ] && g="${g}${SUB}"
  if [ -n "$pr_state" ]; then
    g="${g}${pr_label}:#${pr_num}(${pr_state})"
  else
    g="${g}${pr_label}:#${pr_num}"
  fi
fi
add_group "$g"

# 3) 모델: 이름 · effort · 기본값에서 벗어난 모드만
# 라벨은 값만으로 모호할 때만 붙인다. xhigh 는 effort 말고 될 것이 없으므로 맨값으로
# 두고, off 는 "무엇이 off 인지" 가 값에 없으므로 think: 를 붙인다.
g="${model}"
[ -n "$effort" ] && g="${g}${SUB}${effort}"
[ -n "$thinking_off" ] && g="${g}${SUB}think:off"
[ -n "$fast_mode" ] && g="${g}${SUB}fast"
add_group "$g"

# 4) 컨텍스트
add_group "ctx:${ctx_str}"

# 5) 리밋
g=""
if [ -n "$five_pct" ]; then
  g="5h:$(printf '%.0f' "$five_pct")%"
  [ -n "$five_reset" ] && g="${g} ($(eta "$five_reset"))"
fi
if [ -n "$week_pct" ]; then
  w="7d:$(printf '%.0f' "$week_pct")%"
  [ -n "$week_reset" ] && w="${w} ($(eta "$week_reset"))"
  if [ -n "$g" ]; then
    g="${g}${SUB}${w}"
  else
    g="${w}"
  fi
fi
add_group "$g"

# 6) 모드 (기본값이 아닐 때만)
g=""
if [ -n "$agent_name" ]; then
  g="agent:${agent_name}"
fi
if [ -n "$output_style" ] && [ "$output_style" != "default" ]; then
  [ -n "$g" ] && g="${g}${SUB}"
  g="${g}style:${output_style}"
fi
if [ -n "$vim_mode" ]; then
  [ -n "$g" ] && g="${g}${SUB}"
  g="${g}vim:${vim_mode}"
fi
add_group "$g"

# 7) 꼬리: 버전 · 벽시계
# 시계는 장식이 아니라 위 리셋 카운트다운의 기준점이다. 초는 뺐다
# (refreshInterval 을 10초로 늘려 스폰 비용을 줄이기 위해).
g=""
[ -n "$version" ] && g="v${version}"
[ -n "$g" ] && g="${g}${SUB}"
g="${g}$(date +%H:%M)"
add_group "$g"

printf "%s" "$parts"
