#!/usr/bin/env node
/* Tests for the pure core of regex-builder.html.
 *
 *     node test.js
 *
 * The app is one self-contained HTML file with no module boundary, so rather
 * than duplicating logic here (which would drift), this pulls the functions
 * straight out of the source and evaluates them. If you rename one of the
 * functions listed in NEEDED below, this file fails loudly rather than quietly
 * testing nothing.
 *
 * Scope is deliberately the pure layer — compile / build / blame / restore and
 * their helpers. That is where both real bugs found so far actually lived, and
 * it needs no DOM. Rendering and event wiring are not covered; those still want
 * a browser.
 *
 * Where a claim can be checked against the regex engine itself rather than
 * against my expectations, it is. Group numbering in particular is verified by
 * asking Node's own RegExp how many groups a pattern has.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const SOURCE = path.join(__dirname, "regex-builder.html");

/* ── extracting the source ─────────────────────────────────────────────── */

/* Find the end of a brace-delimited body starting at `from`. Naive brace
   counting breaks immediately here: compile() builds quantifiers with string
   literals like "{" + n + "}", and escLit holds a regex literal full of
   brackets. So this walks the text tracking strings, template literals, regex
   literals and comments, and only counts braces in code position. */
function bodyEnd(src, from) {
  let i = src.indexOf("{", from);
  let depth = 0;

  while (i < src.length) {
    const c = src[i];

    if (c === '"' || c === "'" || c === "`") {
      const quote = c;
      i++;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }

    if (c === "/" && src[i + 1] === "/") { i = src.indexOf("\n", i); continue; }
    if (c === "/" && src[i + 1] === "*") { i = src.indexOf("*/", i) + 2; continue; }

    if (c === "/") {                       // regex literal (no division in this file)
      i++;
      let inClass = false;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === "[") inClass = true;
        else if (src[i] === "]") inClass = false;
        else if (src[i] === "/" && !inClass) { i++; break; }
        else if (src[i] === "\n") break;
        i++;
      }
      continue;
    }

    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return i + 1;
    }
    i++;
  }
  throw new Error("unbalanced braces while extracting");
}

const html = fs.readFileSync(SOURCE, "utf8");
const js = html.slice(html.indexOf("<script>") + 8, html.indexOf("</script>"));

const NEEDED = [
  "PRESETS", "ANCHORS", "LOOKS", "KIND_LABEL", "NAME_OK",
  "isZeroWidth", "newBlock", "escLit", "escClass", "escHtml", "clampInt",
  "rawGroupCount", "compile", "build", "blame", "restore", "EXAMPLES", "mk"
];

function extract(name) {
  const decl = new RegExp("\\n\\s*(?:var\\s+" + name + "\\s*=|function\\s+" + name + "\\b)");
  const m = decl.exec(js);
  if (!m) throw new Error(`could not find "${name}" in ${path.basename(SOURCE)} — was it renamed?`);
  const start = m.index;
  // NAME_OK is a regex literal, not a brace body
  if (name === "NAME_OK") return js.slice(start, js.indexOf(";", start) + 1);
  return js.slice(start, bodyEnd(js, start)) + ";";
}

/* Stubs for the handful of things the extracted code touches. */
const preamble = `
  var uid = 0;
  var state = { blocks: [], flags: { g: true, i: false, m: false, s: false, u: false } };
  var SAVE_KEY = "test", SAVE_VERSION = 1, saveTimer = null;
  var testEl = { value: "" };
  var localStorage = (function () {
    var mem = {};
    return {
      getItem: function (k) { return k in mem ? mem[k] : null; },
      setItem: function (k, v) { mem[k] = String(v); },
      removeItem: function (k) { delete mem[k]; }
    };
  })();
`;

const core = new Function(
  preamble + NEEDED.map(extract).join("\n") +
  "\n return { state: state, get uid() { return uid; }, testEl: testEl, localStorage: localStorage," +
  NEEDED.map(n => `${n}: ${n}`).join(", ") + " };"
)();

/* ── harness ───────────────────────────────────────────────────────────── */

let passed = 0, failed = 0;
const failures = [];

function check(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { passed++; return; }
  failed++;
  failures.push(`${name}\n      expected ${e}\n      actual   ${a}`);
}

function ok(name, cond) { check(name, !!cond, true); }

function group(title) { console.log("\n" + title); }

/* Build a pattern from a list of [kind, props] pairs. */
function pattern(specs) {
  core.state.blocks = specs.map(([kind, props]) => {
    const b = core.newBlock(kind);
    Object.assign(b, props || {});
    return b;
  });
  return core.build();
}

/* Ask the engine how many capture groups a pattern really has. */
function realGroupCount(src) {
  return new RegExp(src + "|").exec("").length - 1;
}

/* The group number the explanation claims for the last captured block. */
function statedGroup(built) {
  const line = built.plain.filter(d => /captured as group/.test(d)).pop();
  return line ? Number(line.match(/group (\d+)/)[1]) : null;
}

/* ── compile: escaping ─────────────────────────────────────────────────── */

group("escaping");
check("literal metacharacters are escaped",
  pattern([["literal", { text: "a.b*c(d)" }]]).pattern, "a\\.b\\*c\\(d\\)");
check("forward slash escaped so the /…/ form stays valid",
  pattern([["literal", { text: "a/b" }]]).pattern, "a\\/b");
check("class keeps - so ranges work",
  pattern([["class", { preset: "custom", custom: "a-z0-9" }]]).pattern, "[a-z0-9]");
check("class escapes ] and \\",
  pattern([["class", { preset: "custom", custom: "]\\" }]]).pattern, "[\\]\\\\]");
check("leading space in a set is preserved",
  pattern([["class", { preset: "custom", custom: " .-" }]]).pattern, "[ .-]");
check("negated set",
  pattern([["class", { preset: "custom", custom: "]", negate: true }]]).pattern, "[^\\]]");

/* ── compile: grouping and quantifiers ─────────────────────────────────── */

group("grouping and quantifiers");
check("single char takes a quantifier directly",
  pattern([["class", { preset: "digit", quant: "plus" }]]).pattern, "\\d+");
check("multi-char literal is wrapped before repeating",
  pattern([["literal", { text: "ab", quant: "plus" }]]).pattern, "(?:ab)+");
check("alternation is bracketed to sit in a sequence",
  pattern([["choice", { options: "cat, dog" }], ["literal", { text: "s" }]]).pattern,
  "(?:cat|dog)s");
check("captured alternation needs no inner group",
  pattern([["choice", { options: "cat, dog", capture: true }]]).pattern, "(cat|dog)");
check("repeated AND captured alternation keeps both",
  pattern([["choice", { options: "cat, dog", quant: "plus", capture: true }]]).pattern,
  "((?:cat|dog)+)");
check("single alternative degrades to a literal",
  pattern([["choice", { options: "cat" }]]).pattern, "cat");
check("lazy quantifier",
  pattern([["class", { preset: "any", quant: "star", lazy: true }]]).pattern, ".*?");
check("open-ended range",
  pattern([["class", { preset: "digit", quant: "range", min: 2, max: "" }]]).pattern, "\\d{2,}");
check("exact count",
  pattern([["class", { preset: "digit", quant: "exact", min: 4 }]]).pattern, "\\d{4}");

/* Repeat must bind tighter than capture, or {4} captures one digit. */
check("capture wraps the repeat, not the other way round",
  pattern([["class", { preset: "digit", quant: "exact", min: 4, capture: true }]]).pattern,
  "(\\d{4})");

/* ── compile: named captures ───────────────────────────────────────────── */

group("named captures");
check("valid name emits a named group",
  pattern([["class", { preset: "digit", capture: true, name: "year" }]]).pattern, "(?<year>\\d)");
check("name starting with a digit falls back to a plain group",
  pattern([["class", { preset: "digit", capture: true, name: "9bad" }]]).pattern, "(\\d)");
check("name with a space falls back",
  pattern([["class", { preset: "digit", capture: true, name: "has space" }]]).pattern, "(\\d)");
check("empty name falls back",
  pattern([["class", { preset: "digit", capture: true, name: "" }]]).pattern, "(\\d)");
check("$ and _ are legal in a name",
  pattern([["class", { preset: "digit", capture: true, name: "ok_$1" }]]).pattern, "(?<ok_$1>\\d)");
check("names are reported to the match table",
  pattern([["class", { preset: "digit", capture: true, name: "year" }]]).names, { 1: "year" });

/* ── lookarounds ───────────────────────────────────────────────────────── */

group("lookarounds");
check("positive lookahead", pattern([["look", { look: "ahead", raw: "\\d" }]]).pattern, "(?=\\d)");
check("negative lookahead", pattern([["look", { look: "nahead", raw: "\\d" }]]).pattern, "(?!\\d)");
check("positive lookbehind", pattern([["look", { look: "behind", raw: "\\d" }]]).pattern, "(?<=\\d)");
check("negative lookbehind", pattern([["look", { look: "nbehind", raw: "\\d" }]]).pattern, "(?<!\\d)");
check("empty lookaround contributes nothing",
  pattern([["look", { look: "ahead", raw: "" }], ["literal", { text: "x" }]]).pattern, "x");
ok("lookarounds are zero-width", core.isZeroWidth("look") && core.isZeroWidth("anchor"));

/* ── group counting ────────────────────────────────────────────────────── */

group("counting groups inside raw fragments");
const rawCounts = [
  ["(\\d+)", 1], ["(?:ab)", 0], ["\\(", 0], ["[()]", 0], ["(?<yr>\\d)", 1],
  ["(?<=x)", 0], ["(?<!x)", 0], ["(?=x)", 0], ["(a)(b)", 2], ["((a)b)", 2], ["", 0]
];
for (const [src, want] of rawCounts) {
  check(`rawGroupCount("${src}") === ${want}`, core.rawGroupCount(src), want);
}

/* The numbering the explanation reports must match what the engine assigns. */
group("stated group numbers agree with the engine");
const numbering = [
  ["raw group before a capture", [["raw", { raw: "(\\d+)" }], ["class", { preset: "digit", capture: true }]]],
  ["non-capturing raw",          [["raw", { raw: "(?:ab)" }], ["class", { preset: "digit", capture: true }]]],
  ["escaped paren",              [["raw", { raw: "\\(" }],    ["class", { preset: "digit", capture: true }]]],
  ["named group in raw",         [["raw", { raw: "(?<yr>\\d)" }], ["class", { preset: "digit", capture: true }]]],
  ["lookbehind in raw",          [["raw", { raw: "(?<=x)" }], ["class", { preset: "digit", capture: true }]]],
  ["group inside a lookaround",  [["look", { look: "ahead", raw: "(\\d+)" }], ["class", { preset: "digit", capture: true }]]],
  ["two raw groups",             [["raw", { raw: "(a)(b)" }], ["class", { preset: "digit", capture: true }]]],
  ["nested raw groups",          [["raw", { raw: "((a)b)" }], ["class", { preset: "digit", capture: true }]]],
  ["captured raw with an inner group",
                                 [["raw", { raw: "(a)b", capture: true }], ["class", { preset: "digit", capture: true }]]]
];
for (const [name, specs] of numbering) {
  const built = pattern(specs);
  check(name, statedGroup(built), realGroupCount(built.pattern));
}

/* ── blame ─────────────────────────────────────────────────────────────── */

group("blaming the block that breaks a pattern");

/* blame() is only ever called from the catch — it assumes the pattern is already
   broken, and on a valid one it would happily "blame" the first removable block.
   So the harness asserts that precondition: if a case stops being invalid, it
   reports "pattern is valid" rather than a misleading block number. */
function blameSeq(specs, flags) {
  const built = pattern(specs);
  flags = flags || "g";
  try {
    new RegExp(built.pattern, flags);
    return "pattern is valid";
  } catch (e) { /* as expected — carry on and find the culprit */ }
  const id = core.blame(built.segs, flags);
  if (id === null) return null;
  return core.state.blocks.findIndex(b => b.id === id) + 1;   // 1-based, as displayed
}

check("unclosed group in the third block",
  blameSeq([["literal", { text: "a" }], ["literal", { text: "b" }],
            ["raw", { raw: "(oops" }], ["literal", { text: "c" }]]), 3);

/* The false positive that per-fragment validation would produce: "+" does not
   compile on its own, but it is perfectly correct sitting after a literal. The
   pattern here is broken by the third block, and that is who must take the fall. */
check("a fragment that is invalid alone but fine in context is not blamed",
  blameSeq([["literal", { text: "a" }], ["raw", { raw: "+" }],
            ["raw", { raw: "(oops" }]]), 3);

check("reversed character range is blamed, though it is no raw block",
  blameSeq([["literal", { text: "x" }], ["class", { preset: "custom", custom: "z-a" }]]), 2);
check("min greater than max is blamed",
  blameSeq([["literal", { text: "y" }],
            ["class", { preset: "digit", quant: "range", min: 5, max: 2 }]]), 2);
check("a well-formed pattern never reaches blame()",
  blameSeq([["literal", { text: "a" }], ["class", { preset: "digit" }]]), "pattern is valid");

/* ── starter examples ──────────────────────────────────────────────────── */

group("starter patterns (regression lock)");
const expectedStarters = {
  email: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,24}",
  date:  "(\\d{4})-(\\d{2})-(\\d{2})",
  hex:   "#([0-9a-fA-F]{6})\\b",
  phone: "(?:\\()?(\\d{3})(?:\\))?[ .-]?(\\d{3})[ .-]?(\\d{4})",
  log:   "^(\\S+) \\S+ (\\S+) \\[([^\\]]+)\\] \"([A-Z]+) (\\S+) HTTP\\/([0-9.]+)\" (\\d{3}) (\\d+|-)"
};
for (const [name, want] of Object.entries(expectedStarters)) {
  core.state.blocks = core.EXAMPLES[name].blocks();
  const built = core.build();
  check(`${name} pattern`, built.pattern, want);
  ok(`${name} compiles`, (() => { try { new RegExp(built.pattern); return true; } catch (e) { return false; } })());
}

/* Each starter must actually match its own sample text. */
group("starters match their sample text");
const expectedHits = { email: 2, date: 2, hex: 2, phone: 3, log: 3 };
for (const [name, hits] of Object.entries(expectedHits)) {
  const ex = core.EXAMPLES[name];
  core.state.blocks = ex.blocks();
  const built = core.build();
  const flags = "g" + (ex.flags && ex.flags.m ? "m" : "");
  check(`${name} finds ${hits}`, (ex.test.match(new RegExp(built.pattern, flags)) || []).length, hits);
}

/* ── restore ───────────────────────────────────────────────────────────── */

group("restoring saved work");
function saved(obj) { core.localStorage.setItem("test", JSON.stringify(obj)); }
function freshRestore() { core.state.blocks = []; return core.restore(); }

saved({ v: 1,
  blocks: [{ id: 7, kind: "look", look: "nahead", raw: "\\d" },
           { id: 8, kind: "class", capture: true, name: "tail" }],
  flags: { g: true, m: true }, test: "persist me" });
ok("restore reports success", freshRestore() === true);
check("ids are renumbered for the new session",
  core.state.blocks.map(b => b.id), [1, 2]);
check("kinds survive", core.state.blocks.map(b => b.kind), ["look", "class"]);
check("name survives", core.state.blocks[1].name, "tail");
check("a field absent from the save gets its default", core.state.blocks[0].quant, "one");
check("flags merge", [core.state.flags.g, core.state.flags.m], [true, true]);
check("test text restored", core.testEl.value, "persist me");
check("restored blocks still compile", core.build().pattern, "(?!\\d)(?<tail>\\d)");

core.localStorage.setItem("test", "{not json");
ok("malformed JSON is rejected", freshRestore() === false);
saved({ v: 99, blocks: [] });
ok("a future save version is rejected", freshRestore() === false);
saved({ v: 1, blocks: "nope" });
ok("a non-array blocks field is rejected", freshRestore() === false);
saved({ v: 1, blocks: [] });
ok("an empty canvas restores as empty", freshRestore() === true && core.state.blocks.length === 0);
saved({ v: 1, blocks: [{ kind: "bogus" }, { kind: "literal", text: "ok" }] });
freshRestore();
check("an unknown block kind is dropped, the rest kept",
  core.state.blocks.map(b => b.text), ["ok"]);

/* ── summary ───────────────────────────────────────────────────────────── */

console.log("");
if (failed) {
  console.log(`${failed} FAILED, ${passed} passed\n`);
  failures.forEach(f => console.log("  ✗ " + f + "\n"));
  process.exit(1);
}
console.log(`all ${passed} checks passed`);
