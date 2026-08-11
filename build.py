#!/usr/bin/env python3
"""Build publishable copies of regex-builder.html with the comments scrubbed.

The working draft keeps every explanatory comment — it is the source of record
and should stay heavily annotated. This script produces the copies meant for
publication, where that commentary is stripped out.

    python3 build.py                 run the test suite, then build
    python3 build.py --skip-tests    build without running it

Writes:
    docs/index.html           the published site. GitHub Pages serves /docs on
                              the main branch, so this is committed, not ignored
    dist/artifact-body.html   the same page minus the <html>/<head>/<body>
                              wrapper, for hosts supplying their own skeleton.
                              dist/ is scratch and gitignored

test.js runs first and a failure aborts the build, so dist/ can never hold a
version that does not pass. A suite that cannot be run is not the same as one
that fails: a missing node or a missing test.js warns and carries on, since
neither is evidence of a broken page.

Nothing else is touched: no minification, no reordering, no renaming. The only
difference between the draft and the output is the absence of comments, so a
diff of the two is easy to eyeball before shipping.

On stripping JavaScript safely: naive regex-based comment removal corrupts code
whenever "//" or "/*" appears inside a string or a regex literal — and this file
is full of regex literals. The scanner below walks the source character by
character, tracking whether it sits inside a string, a template literal, or a
regex literal (including a [...] class, where "/" does not terminate the
pattern), and only removes a comment when it is genuinely in code position.

It relies on one property of this specific file, verified before writing it:
there is no division operator anywhere in the script, so every "/" found in code
position begins either a comment or a regex literal. Should real arithmetic ever
be added, revisit assert_no_division() below.
"""

import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).parent
SRC = HERE / "regex-builder.html"
TESTS = HERE / "test.js"
OUT_DIR = HERE / "dist"
DOCS_DIR = HERE / "docs"


def run_tests() -> None:
    """Gate the build on the suite. Exits non-zero on failure, writing nothing."""
    if "--skip-tests" in sys.argv:
        print("tests   skipped (--skip-tests)")
        return
    if not TESTS.exists():
        print(f"tests   skipped — no {TESTS.name}")
        return
    if shutil.which("node") is None:
        print("tests   skipped — node not on PATH")
        return

    result = subprocess.run(["node", str(TESTS)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        sys.exit("\nbuild.py: tests failed — dist/ left untouched")

    summary = [ln for ln in result.stdout.strip().split("\n") if ln.strip()]
    print("tests   " + (summary[-1] if summary else "passed"))


def strip_js_comments(js: str) -> str:
    """Remove // and /* */ comments, leaving strings and regex literals intact."""
    out = []
    i, n = 0, len(js)

    while i < n:
        c = js[i]

        # strings and template literals — copied through verbatim
        if c in "\"'`":
            quote = c
            out.append(c)
            i += 1
            while i < n:
                if js[i] == "\\":            # escape: take both characters
                    out.append(js[i:i + 2])
                    i += 2
                    continue
                out.append(js[i])
                i += 1
                if js[i - 1] == quote:
                    break
            continue

        if c == "/" and i + 1 < n:
            nxt = js[i + 1]

            if nxt == "/":                   # line comment — drop to the newline
                end = js.find("\n", i)
                i = end if end != -1 else n
                continue

            if nxt == "*":                   # block comment — drop through */
                end = js.find("*/", i + 2)
                i = end + 2 if end != -1 else n
                continue

            # otherwise a regex literal (see module docstring)
            out.append(c)
            i += 1
            in_class = False
            while i < n:
                ch = js[i]
                if ch == "\\":
                    out.append(js[i:i + 2])
                    i += 2
                    continue
                if ch == "\n":               # unterminated: bail rather than eat code
                    break
                out.append(ch)
                i += 1
                if ch == "[":
                    in_class = True
                elif ch == "]":
                    in_class = False
                elif ch == "/" and not in_class:
                    break
            continue

        out.append(c)
        i += 1

    return "".join(out)


def assert_no_division(js: str) -> None:
    """Guard the assumption the JS scanner rests on."""
    probe = strip_js_comments(js)
    # blank out strings, then any surviving "/" must have been a regex literal
    probe = re.sub(r'"(\\.|[^"\\])*"', '""', probe)
    probe = re.sub(r"'(\\.|[^'\\])*'", "''", probe)
    for lineno, line in enumerate(probe.split("\n"), 1):
        if re.search(r"[\w\)\]]\s*/\s*[\w\(]", line) and not line.lstrip().startswith("/"):
            if not re.search(r"/[^/\n]*/[gimsuy]*", line):
                sys.exit(f"build.py: possible division at line {lineno} — "
                         f"the comment scanner's assumption no longer holds:\n  {line.strip()}")


def collapse_blank_runs(text: str) -> str:
    """A removed comment leaves a hole; close up runs of blank lines."""
    text = re.sub(r"[ \t]+(\n)", r"\1", text)
    return re.sub(r"\n{3,}", "\n\n", text)


def main() -> None:
    run_tests()
    src = SRC.read_text()

    style = re.search(r"<style>(.*?)</style>", src, re.S)
    script = re.search(r"<script>(.*?)</script>", src, re.S)
    if not style or not script:
        sys.exit("build.py: could not find the <style> or <script> block")

    assert_no_division(script.group(1))

    scrubbed = src
    # CSS: no /* sequences occur inside CSS strings in this file
    scrubbed = scrubbed.replace(style.group(1), re.sub(r"/\*.*?\*/", "", style.group(1), flags=re.S))
    scrubbed = scrubbed.replace(script.group(1), strip_js_comments(script.group(1)))
    scrubbed = re.sub(r"<!--.*?-->", "", scrubbed, flags=re.S)
    scrubbed = collapse_blank_runs(scrubbed)

    DOCS_DIR.mkdir(exist_ok=True)
    (DOCS_DIR / "index.html").write_text(scrubbed)

    # wrapper-free variant for hosts that supply their own page skeleton
    OUT_DIR.mkdir(exist_ok=True)
    body = re.search(r"<body>(.*)</body>", scrubbed, re.S).group(1)
    css = re.search(r"<style>.*?</style>", scrubbed, re.S).group(0)
    (OUT_DIR / "artifact-body.html").write_text("<title>Regex Composer</title>\n" + css + body)

    draft_lines = len(src.split("\n"))
    out_lines = len(scrubbed.split("\n"))
    print(f"draft   {draft_lines:>5} lines  {len(src) / 1024:>6.1f} KB")
    print(f"built   {out_lines:>5} lines  {len(scrubbed) / 1024:>6.1f} KB"
          f"   ({draft_lines - out_lines} lines of commentary removed)")
    print("        docs/index.html  +  dist/artifact-body.html")


if __name__ == "__main__":
    main()
