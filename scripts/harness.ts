// harness.ts — drives the registered tools (read/edit/write/grep) of pi-encoding-fs
// against copies of Ousret/char-dataset files and verifies the bytes on disk.
// Cross-platform: only Node built-ins (TextDecoder) are used as the independent reference.
//
// usage: vite-node harness.ts <runDir> <extensionRepoDir>
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const WORK = process.argv[2];
const REPO = process.argv[3];
if (!WORK || !REPO) throw new Error("usage: harness.ts <runDir> <extensionRepoDir>");
process.chdir(WORK);

const imp = (p: string) => import(pathToFileURL(p).href);
const tools = new Map<string, any>();
const mod: any = await imp(join(REPO, "src", "index.ts"));
mod.default({ registerTool: (t: any) => tools.set(t.name, t), on: () => {} });
const none = undefined as never;

const run = async (name: string, params: any) => {
  try {
    const r = await tools.get(name).execute("t", params, none, none, none);
    return { ok: true, text: r.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n") };
  } catch (e: any) {
    return { ok: false, text: String(e.message) };
  }
};

// ── independent reference decoders (Node built-ins, not iconv-lite) ──────────
const LATIN9: Record<number, string> = {
  0xa4: "€", 0xa6: "Š", 0xa8: "š", 0xb4: "Ž",
  0xb8: "ž", 0xbc: "Œ", 0xbd: "œ", 0xbe: "Ÿ",
};
type Enc = "latin1" | "latin9" | "cp1252" | "gb18030" | "utf8";
const decode = (enc: Enc, b: Buffer): string => {
  switch (enc) {
    case "latin1": return b.toString("latin1");
    case "latin9": return [...b].map((x) => LATIN9[x] ?? String.fromCharCode(x)).join("");
    case "cp1252": return new TextDecoder("windows-1252").decode(b);
    case "gb18030": return new TextDecoder("gb18030").decode(b);
    case "utf8": return new TextDecoder("utf-8", { ignoreBOM: true }).decode(b);
  }
};
const isUtf8 = (b: Buffer) => {
  try { new TextDecoder("utf-8", { fatal: true }).decode(b); return true; } catch { return false; }
};
const hasFFFD = (b: Buffer) => b.includes(Buffer.from([0xef, 0xbf, 0xbd]));
const hex = (b: Buffer) => b.toString("hex");

const DIRS: Array<[string, Enc]> = [
  ["iso8859_1", "latin1"], ["windows_1252", "cp1252"], ["gb18030", "gb18030"], ["utf_guard", "utf8"],
];
const haveRg = spawnSync("rg", ["--version"], { stdio: "ignore", windowsHide: true }).status === 0;

let pass = 0, fail = 0, known = 0, skipped = 0;
const check = (label: string, cond: boolean, info = "", knownLimit = false) => {
  if (cond) pass++;
  else if (knownLimit) known++;
  else fail++;
  console.log(`${cond ? "PASS" : knownLimit ? "KNOWN" : "FAIL"}  ${label}${info ? "  — " + info : ""}`);
};
const skip = (msg: string) => { skipped++; console.log(`SKIP  ${msg}`); };

console.log("tools registered:", [...tools.keys()].join(", "));
if (!haveRg) console.log("note: ripgrep (rg) not found on PATH -> grep checks are skipped");

for (const [dir, enc] of DIRS) {
  for (const f of readdirSync(join(WORK, dir)).filter((n) => !n.startsWith("."))) {
    const p = join(WORK, dir, f);
    const orig = readFileSync(p);
    const tag = `${dir}/${f}`;
    const text = decode(enc, orig);
    const btext = text.replace(/^﻿/, "");
    const first = btext.search(/[^\x00-\x7f]/);
    const word = first < 0 ? "" : (btext.slice(Math.max(0, first - 8), first + 8).split(/\s/).find((w) => /[^\x00-\x7f]/.test(w)) ?? "");

    // READ
    const rd = await run("read", { path: p });
    check(`read   ${tag}`, rd.ok && !rd.text.includes("�") && (word === "" || rd.text.includes(word)),
      `${orig.length} B, probe "${word}"`);
    if (first < 0) { skip(`${tag}: ASCII-only after BOM, edit/write/grep not exercised`); continue; }

    // GREP (before editing, on the original word)
    if (haveRg) {
      const g = await run("grep", { pattern: word, literal: true, path: join(WORK, dir) });
      check(`grep   ${tag}`, g.ok && g.text.includes(f), `"${word}"`, dir === "utf_guard");
    }

    // EDIT: unique window around the first non-ASCII char, append a marker
    let old = "";
    for (let k = 3; k < 120; k += 6) {
      old = btext.slice(Math.max(0, first - k), first + k).split(/\r?\n/).find((l) => /[^\x00-\x7f]/.test(l)) ?? "";
      if (old && btext.split(old).length === 2) break;
    }
    if (!old || btext.split(old).length !== 2) { skip(`edit ${tag}: no unique snippet`); continue; }
    const nw = old + "[EDIT]";
    const er = await run("edit", { path: p, edits: [{ oldText: old, newText: nw }] });
    const after = readFileSync(p);
    if (dir === "utf_guard") {
      // UTF-8 must stay UTF-8 and behave exactly like stock Pi (no extension loaded)
      // (harness is executed from inside the extension repo, so the bare import resolves)
      const pm: any = await import("@earendil-works/pi-coding-agent");
      const pp = join(WORK, "plain", f);
      await pm.createEditToolDefinition(join(WORK, "plain")).execute("p", { path: pp, edits: [{ oldText: old, newText: nw }] }, none, none, none);
      check(`edit   ${tag}`, er.ok && isUtf8(after) && after.equals(readFileSync(pp)), "stays UTF-8, identical to stock Pi edit");
    } else {
      check(`edit   ${tag}`,
        er.ok && decode(enc, after) === text.replace(old, nw) && after.length - orig.length === 6 && !hasFFFD(after),
        `size +${after.length - orig.length} B (expect +6), decoded text == expected${er.ok ? "" : ", ERR " + er.text.slice(0, 140)}`);
    }

    // WRITE: rewrite the whole file with its own text + marker; bytes must be previous + "ZZZ"
    const wr = await run("write", { path: p, content: decode(enc, after) + "ZZZ" });
    const after2 = readFileSync(p);
    check(`write  ${tag}`, wr.ok && after2.equals(Buffer.concat([after, Buffer.from("ZZZ")])),
      `== previous + "ZZZ"${wr.ok ? "" : ", ERR " + wr.text.slice(0, 140)}`);
  }
}

// € cannot be stored in ISO-8859-1 -> refused, file untouched
{
  const p = join(WORK, "iso8859_1", "_ude_1.txt");
  const before = readFileSync(p);
  const r = await run("write", { path: p, content: decode("latin1", before) + "Preis 5 €\n" });
  check("write € into ISO-8859-1 file is refused, file unchanged", !r.ok && readFileSync(p).equals(before), r.text.slice(-170));
}
// brand-new files are created in the configured encoding
for (const [dir, enc, content, want] of [
  ["iso8859_15", "latin9", "Preis 5 € Grüße\n", [0xa4]],
  ["windows_1252", "cp1252", "„Grüße“ 5 €\n", [0x84, 0x93, 0x80]],
  ["iso8859_1", "latin1", "Grüße, Jürgen\n", [0xfc]],
] as Array<[string, Enc, string, number[]]>) {
  const p = join(WORK, dir, "neu.txt");
  const r = await run("write", { path: p, content });
  const bytes = existsSync(p) ? readFileSync(p) : Buffer.alloc(0);
  check(`write new file in ${dir}`, r.ok && want.every((x) => bytes.includes(x)) && decode(enc, bytes) === content && !isUtf8(bytes) && !hasFFFD(bytes),
    `bytes ${hex(bytes)}`);
}
// unsupported encoding -> clear error, no silent UTF-8 fallback
{
  const f = readdirSync(join(WORK, "cp1250")).filter((n) => !n.startsWith("."))[0];
  const r = await run("read", { path: join(WORK, "cp1250", f) });
  check("unsupported windows-1250 -> clear error", !r.ok && /Unsupported encoding/.test(r.text) && /Supported:/.test(r.text), r.text.slice(0, 200));
}

console.log(`\n${pass} passed, ${fail} failed, ${known} known limitation(s), ${skipped} skipped`);
process.exit(fail ? 1 : 0);
