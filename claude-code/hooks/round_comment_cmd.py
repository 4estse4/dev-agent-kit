# `gh pr comment` 명령을 읽는다. 라운드 코멘트를 보는 두 훅(round_comment_quotes.sh · round_comment_cold.sh)이
# 같이 쓴다. 두 훅이 받는 게시 모양이 한 벌이어야 한쪽이 받는 모양이 다른 쪽의 대조를 피해 가지 않는다 —
# 따로 읽던 동안 콜드 대조 훅은 `--body-file <경로>` 를 끝에 둔 모양만 보고 `-F` · `--body-file=` 로 올린
# 라운드 코멘트를 대조 없이 통과시켰다.
#
# parse(명령) 는 (종류, 값) 을 돌려준다:
#   ('none', None)   게시일 수 있는 명령이 아니다
#   ('deny', 사유)   정규형이 아니다. 훅은 이 사유로 막는다
#   ('skip', None)   본문을 올리지 않는다(`--help` · `--delete-last` 등)
#   ('ok', {'pr', 'repo', 'path'})  정규형이다. path 는 절대 경로다
#
# 명령 글자 어디에든 `gh` · `pr` · `comment` 가 이 순서로 붙어 있으면(사이에는 플래그만) 게시일
# 수 있는 명령이다. 앞에 무엇이 오든, 따옴표 · heredoc 안이든 가리지 않는다. 「명령 자리」를
# 목록으로 정해 알아보던 동안 목록 밖(`if` · `timeout` · `bash -lc` · `find -exec` …)의 게시가
# 대조 없이 올라갔다. 따옴표로 감싼 낱말과 경로를 붙인 `gh` 도 알아본다.
import os
import re
import shlex

CANON = "`gh pr comment <N> [-R <레포>] --body-file <절대 경로>`"
_FLAGS = r"(?:-\S+\s+(?:[^-\s;&|]\S*\s+)?)*"
CAND = re.compile(
    r'(?<![\w.-])["\']?(?:[^\s"\']*/)?gh["\']?\s+'
    + _FLAGS
    + r'["\']?pr["\']?\s+'
    + _FLAGS
    + r'["\']?comment["\']?(?![\w-])'
)
# 정규형이 받는 플래그. `gh pr comment --help` 의 FLAGS · INHERITED FLAGS 그대로다.
VALUED = {
    "-R": "repo",
    "--repo": "repo",
    "-F": "file",
    "--body-file": "file",
    "-b": "body",
    "--body": "body",
}
BOOLS = {
    "--create-if-none",
    "--delete-last",
    "--edit-last",
    "--yes",
    "-e",
    "--editor",
    "-w",
    "--web",
    "-h",
    "--help",
}


def _canon(why):
    return (
        "deny",
        "gh pr comment 는 한 줄 정규형으로 따로 입력해라: "
        + CANON
        + ". "
        + why
        + " 게시가 아니면 그 글자를 명령에서 빼라. 찾을 때는 `pr comment` 로 찾고, "
        "파일은 Write 도구로 쓴다.",
    )


def parse(cmd):
    cmd = cmd.replace("\\\n", " ")
    if not CAND.search(cmd):
        return ("none", None)
    line = cmd.strip()
    if "\n" in line:
        return _canon("줄바꿈으로 다른 명령과 이으면 이 훅이 무엇이 올라가는지 믿을 수 없다.")
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError:
        return _canon("명령을 읽지 못했다.")
    if len(toks) < 3 or os.path.basename(toks[0]) != "gh" or toks[1:3] != ["pr", "comment"]:
        return _canon("앞붙임 · 래퍼 · 하위 명령 앞의 플래그는 받지 않는다.")
    if any(set(t) <= set("();<>|&") or t.startswith("#") for t in toks):
        return _canon(
            "다른 명령 · 주석 · 리다이렉트와 이으면 이 훅이 무엇이 올라가는지 믿을 수 없다."
        )

    pr, got, bools = [], {}, set()
    args = toks[3:]
    j = 0
    while j < len(args):
        a = args[j]
        name, val = a, None
        if a.startswith("--") and "=" in a:
            name, val = a.split("=", 1)
        elif re.match(r"^-[RFb].", a):  # 짧은 플래그에 값을 붙인 `-Fx` · `-F=x`
            name, val = a[:2], a[2:]
            if val.startswith("="):
                val = val[1:]
        if name in VALUED:
            if val is None:
                j += 1
                if j >= len(args):
                    return _canon(name + " 에 값이 없다.")
                val = args[j]
            if VALUED[name] in got:
                return _canon(name + " 가 두 번 나왔다.")
            got[VALUED[name]] = val
        elif name in BOOLS and val is None:
            bools.add(name)
        elif not a.startswith("-"):
            pr.append(a)
        else:
            return _canon("모르는 플래그다: " + a)
        j += 1

    if bools & {"-h", "--help"}:
        return ("skip", None)
    if "body" in got or bools & {"-e", "--editor", "-w", "--web"}:
        return (
            "deny",
            "gh pr comment 의 본문은 절대 경로 파일 하나로만 전달한다: "
            + CANON
            + ". 인라인 본문 · 편집기 · 웹은 이 훅이 판정할 수 없다.",
        )
    if "file" not in got:
        return ("skip", None)  # 본문 없이는 새 글을 안 올린다(`--delete-last` 등)
    if len(pr) != 1 or not re.match(r"^\d+$", pr[0]):
        return _canon("PR 은 번호 하나로 적는다(URL · 브랜치 이름은 받지 않는다).")
    path = got["file"]
    if not os.path.isabs(path):
        return (
            "deny",
            "gh pr comment 의 --body-file 에 상대 경로를 전달했다. 이 훅은 명령 안의 cd 를 못 "
            "따라가므로 절대 경로만 받는다: " + CANON,
        )
    return ("ok", {"pr": pr[0], "repo": got.get("repo"), "path": path})
