# GitHub 에 올리는 글의 길이를 센다. 훅 post_length.sh 가 표준입력의 도구 호출로 이 파일을 실행한다.
#
# **무엇을 세나.** GitHub 이 그린 화면에 보이는 글자다. 공백을 포함하고, 이어진 공백은 한 칸으로 센다. 한글 · 영문 ·
# 숫자 · 기호 모두 한 자이고 마크다운 문법은 세지 않는다. 그래서 게시할 글을 GitHub 의 markdown API 로 그려
# (gfm, 레포 context) 태그를 지운 글자를 센다. 원문 마크다운의 글자 수는 문법 · 링크 주소 · 접힌 블록이 섞여 기준이
# 되지 않았다. 접힌 블록(`<details>`)은 `<summary>` 만 센다. 펼쳐 둔 블록(`<details open>`)은 안까지 센다.
#
# **검사 둘.** 접히지 않은 부분 전체(총량)와, 코드 블록을 뺀 접히지 않은 줄 하나(문단 하나 · 목록 항목 하나 · 표 칸
# 하나). 한 줄 상한은 산문 문단을 막고, 총량 상한은 펼친 출력을 막는다 — 출력은 접어야 빠진다. 줄 수는 화면 폭마다
# 달라져 쓰지 않는다. 문단이나 항목 안에서 원문의 줄을 바꾼 자리(GitHub 은 `<br>` 로 그린다)는 앞 줄에 이어 센다.
# `→` 로 시작하는 줄만 따로 센다 — GitHub 글은 문단과 항목을 한 줄로 쓰고, 항목 아래 `→` 줄만 일부러 바꾼다. 이어
# 세지 않으면 산문 문단 안에 줄바꿈만 넣어도 한 줄 검사를 통과했다.
#
# **상한.** 개조식으로 고쳐 쓴 PR 본문 · 라운드 코멘트 · 결정 코멘트의 가장 긴 줄과 총량보다 크고, 산문 문단 한
# 개와 펼친 출력이 든 결정 코멘트는 막히게 정했다. 스킬 문서는 숫자를 옮겨 적지 않고 이 파일을 가리킨다.
import html
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

import round_comment_cmd

LINE_MAX = 150
TOTAL_MAX = 2000
TIMEOUT = 30

# `gh pr comment` 는 인용 훅과 같은 해석(round_comment_cmd)으로 읽는다. 그 밖에 보는 게시 명령이다. 본문을 고쳐 쓰는
# `gh pr edit` · `gh issue edit` 는 보지 않는다 — 상한보다 먼저 쓴 긴 본문은 한 줄만 고쳐도 막힌다.
SUBS = {("pr", "create"), ("issue", "create"), ("issue", "comment")}
CAND = re.compile(
    r"(?<![\w.-])gh\s+(?:\S+\s+)*?(?:pr|issue)\s+(?:\S+\s+)*?(?:create|comment)(?![\w-])"
)
# 값을 받는 플래그. 하위 명령 앞에 와도(`gh -R <레포> issue create` · `gh issue -R <레포> create`) 값을 건너뛴다
VALUED = {
    "-F": "file",
    "--body-file": "file",
    "-b": "body",
    "--body": "body",
    "-R": "repo",
    "--repo": "repo",
}
NOBODY = {"-w", "--web", "-h", "--help"}
OPS = set("();<>|&")
BR = re.compile(r"<br>\s*\n(?!\s*→)")
FIX = (
    "산문 문단은 항목 하나에 한 줄로 나누고, 명령 출력은 evidence.sh --fold 로 접는다. 라운드 코멘트가 총량에"
    " 막히면 심각도가 모두 낮음인 항목을 바구니마다 접는다(open-pr 의 comment-format.md)."
)


def deny(why):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": why,
                }
            },
            ensure_ascii=False,
        )
    )
    sys.exit(0)


def visible(h, drop_pre=False):
    def summary(m):
        s = re.search(r"<summary>(.*?)</summary>", m.group(0), flags=re.S)
        return s.group(1) if s else ""

    h = re.sub(r"<details>.*?</details>", summary, h, flags=re.S)
    if drop_pre:
        h = re.sub(r"<pre.*?</pre>", "", h, flags=re.S)
    return html.unescape(re.sub(r"<[^>]+>", "", h))


def width(s):
    return len(re.sub(r"\s+", " ", s).strip())


def count(h):
    """(총량, [(줄의 글자 수, 줄)]) — 줄은 코드 블록을 뺀 접히지 않은 줄이다."""
    h = BR.sub(" ", h)
    lines = [(width(x), x.strip()) for x in visible(h, True).splitlines() if x.strip()]
    return width(visible(h)), lines


def posts(cmd, cwd):
    """명령에서 게시할 글을 찾는다. ('file', 경로, 레포) 또는 ('text', 글, 레포)."""
    found = []
    kind, got = round_comment_cmd.parse(cmd)
    if kind == "ok":
        found.append(("file", got["path"], got["repo"]))
    if not CAND.search(cmd):
        return found
    try:
        lex = shlex.shlex(cmd.replace("\\\n", " "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError:
        deny("게시 명령을 읽지 못해 길이를 세지 못했다. 본문은 파일로 주고 명령을 따로 입력한다.")
    for i, t in enumerate(toks):
        if os.path.basename(t) != "gh":
            continue
        words, got, j = [], {}, i + 1
        while j < len(toks) and not set(toks[j]) <= OPS:
            a = toks[j]
            name, val = a, None
            if a.startswith("--") and "=" in a:
                name, val = a.split("=", 1)
            elif re.match(r"^-[FbR].", a):  # 짧은 플래그에 값을 붙인 `-Fx` · `-F=x`
                name, val = a[:2], a[2:].removeprefix("=")
            if name in VALUED:
                if val is None:
                    j += 1
                    val = toks[j] if j < len(toks) else ""
                got[VALUED[name]] = val
            elif name in NOBODY:
                got["nobody"] = True
            elif not a.startswith("-") and len(words) < 2:
                words.append(a)
            j += 1
        if tuple(words) not in SUBS:
            continue
        body, text, repo = got.get("file"), got.get("body"), got.get("repo")
        if body == "-":
            deny(
                "본문을 표준입력으로 주면 길이를 셀 수 없다. 본문은 파일로 준다(--body-file <파일>)."
            )
        if body is not None:
            path = os.path.expanduser(body)
            found.append(("file", path if os.path.isabs(path) else os.path.join(cwd, path), repo))
        elif text is not None:
            found.append(("text", text, repo))
        elif tuple(words) == ("pr", "create") and not got.get("nobody"):
            deny(
                "본문 없이 여는 gh pr create(--fill 처럼 커밋으로 채우는 것)는 길이를 셀 수 없다. "
                "본문은 파일로 준다(--body-file <파일>)."
            )
    return found


def gh(args, cwd):
    try:
        r = subprocess.run(["gh", *args], cwd=cwd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        deny(f"길이를 세지 못했다(gh {args[0]} 가 {TIMEOUT}초 안에 끝나지 않았다).")
    except OSError as e:
        deny(f"길이를 세지 못했다(gh {args[0]} 를 실행하지 못했다: {e}).")
    if r.returncode:
        deny(f"길이를 세지 못했다(gh {args[0]}: {(r.stderr or r.stdout).strip()[:200]}).")
    return r.stdout


def check(h):
    total, lines = count(h)
    longest = max((n for n, _ in lines), default=0)
    over = [(n, x) for n, x in lines if n > LINE_MAX]
    if total <= TOTAL_MAX and not over:
        return
    why = (
        "접히지 않은 부분이 상한을 넘는다(GitHub 이 그린 글자, 공백 포함, 접힌 블록은 summary 만). "
    )
    why += f"총량 {total}자(상한 {TOTAL_MAX}) · 가장 긴 줄 {longest}자(상한 {LINE_MAX})."
    if over:
        why += " 넘는 줄: " + " · ".join(f"「{x[:20]}…」 {n}자" for n, x in over[:3])
        if len(over) > 3:
            why += f" 외 {len(over) - 3}줄"
        why += "."
    deny(why + " " + FIX)


def main():
    try:
        data = json.loads(os.environ["HOOK_INPUT"])
    except ValueError:
        return
    if data.get("tool_name") != "Bash":
        return
    cwd = data.get("cwd") or None
    found = posts((data.get("tool_input") or {}).get("command") or "", cwd or os.getcwd())
    here = None
    for kind, val, repo in found:
        if kind == "file":
            try:
                with open(val, encoding="utf-8") as fh:
                    fh.read()
            except (OSError, UnicodeDecodeError) as e:
                deny(f"본문 파일 {val} 을 읽지 못해 길이를 세지 못했다({e}).")
            path = val
        else:
            fd, path = tempfile.mkstemp(suffix=".md")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(val)
        if not repo:
            if here is None:
                here = gh(
                    ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cwd
                ).strip()
            repo = here
        args = ["api", "--method", "POST", "markdown", "-f", "mode=gfm", "-f", "context=" + repo]
        try:
            h = gh([*args, "-F", "text=@" + path], cwd)
        finally:
            if kind == "text":
                os.unlink(path)
        check(h)


if __name__ == "__main__":
    main()
