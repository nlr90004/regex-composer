# Regex Composer

Build a regular expression out of labelled blocks. The pattern assembles as you
go, runs against your test text live, and reads itself back in plain English.

**Live:** https://regex.nlr.wtf/

No dependencies, no framework, no build step for the app itself — it is one HTML
file you can open from disk.

## Blocks

| Block | Produces |
|---|---|
| Text | a literal, escaped for you |
| Character | `\d` `\w` `\s`, letters, or a custom set like `A-Za-z0-9._%+-` |
| One of | alternation — `(?:http\|https\|ftp)` |
| Anchor | `^` `$` `\b` `\B` |
| Lookaround | `(?=…)` `(?!…)` `(?<=…)` `(?<!…)` |
| Raw | anything the blocks do not cover |

Each block takes a repeat (`?` `+` `*` `{n}` `{n,m}`), lazy and capture toggles,
and an optional group name. Five starter patterns are built in, including an
Apache/nginx log line with eight capture groups.

## Layout of the repo

```
regex-builder.html   the working draft — heavily commented, source of record
build.py             runs the tests, strips the comments, writes the outputs
test.js              81 checks over the pure core, no dependencies
docs/index.html      the published site (GitHub Pages serves /docs)
```

`regex-builder.html` keeps every explanatory comment on purpose. `build.py`
produces the copies meant for publication, so the annotated draft and the
shipped page never diverge by hand.

## Working on it

```bash
node test.js       # 81 checks
python3 build.py   # tests, then rebuild docs/ and dist/
```

`build.py` refuses to write anything if the suite fails, so what is published
has always passed. `--skip-tests` overrides that and says so in its output.

The tests extract `compile`, `build`, `blame`, `restore` and friends directly
out of the HTML rather than duplicating them, so they cannot drift from the
source — and a renamed function fails loudly instead of silently testing
nothing. Group numbering is verified against the JavaScript engine itself
rather than against hand-written expectations.

## Known limits

- Blocks do not nest. Anything structural — a quantified sub-sequence, a group
  around several blocks — needs a Raw block.
- The group counter reads raw fragments textually rather than parsing them. It
  handles escapes, character classes, named groups and lookarounds, but an
  unusual enough fragment could still fool it.
- The match table shows the first 200 matches; the scanner stops at 10,000.
