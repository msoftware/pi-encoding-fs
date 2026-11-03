# pi-encoding-fs

**English** | [Deutsch](README.de.md)

Encoding-aware `read` / `write` / `edit` / `grep` for [Pi](https://github.com/earendil-works).
Transparently handles GB18030 / GBK / GB2312 and ISO-8859-1 / ISO-8859-15 / Windows-1252
files while preserving Pi's native TUI
(diff view, syntax highlighting, line numbers).

> This is the [msoftware fork](https://github.com/msoftware/pi-encoding-fs) of
> [15wtyuan/pi-encoding-fs](https://github.com/15wtyuan/pi-encoding-fs). It adds
> ISO-8859-1, ISO-8859-15 and Windows-1252 support (see [CHANGELOG](CHANGELOG.md)).

## How it works

The extension registers tools with the same names as Pi's built-ins, overriding them.
`read`/`write`/`edit` reuse Pi's own tool skeletons via `createXxxToolDefinition`, injecting
encoding conversion only at the byte-IO layer, so Pi keeps computing and rendering diffs in
UTF-8. `grep` is self-implemented so it can search non-ASCII text (Chinese, umlauts, …) inside legacy-encoded files.

Encoding is decided **per file**: the extension walks up from the file's directory to the
nearest `.encoding-converter.json`. If none is found, it passes through as plain UTF-8
(identical to not having the extension installed).

The extension also injects a short note into the system prompt so the agent knows the
built-in tools already handle legacy↔UTF-8 transcoding (no need to run `iconv` or re-save
files), and — when no config exists — how to create a `.encoding-converter.json` itself
if it ever reads garbled Chinese or broken umlauts. The note is constant so prompt caching stays effective.

## Configuration

Place `.encoding-converter.json` in any directory. It applies to files in that directory
and in all of its subdirectories, at any depth, unless a deeper config overrides it.

Configs are **not merged**: for each file only the nearest config counts. A config in a
subdirectory fully replaces the one above it, including its `overrides`, `utf8Guard` and
`confidenceThreshold` (unset values fall back to the built-in defaults, not to the parent
config). To treat individual paths differently without a second config, use `overrides`.

```json
{
  "sourceEncoding": "GB18030",
  "confidenceThreshold": 0.8,
  "overrides": [
    { "pattern": "docs/**", "sourceEncoding": "UTF-8" },
    { "pattern": "legacy/**", "sourceEncoding": "GBK" }
  ]
}
```

- `sourceEncoding`: default encoding (when GB detection is uncertain); also used for new files.
- `confidenceThreshold`: minimum chardet confidence (0-1) to trust auto-detection (GB only).
- `utf8Guard` (default `true`): under a single-byte `sourceEncoding`, a file that starts with a
  UTF-8 BOM or is fully valid UTF-8 containing non-ASCII characters is treated as UTF-8 and
  written back as UTF-8. Set `false` to always apply the configured encoding.
- `overrides`: glob rules relative to the config file's directory; most specific wins.

### Supported encodings

`UTF-8`, `GB18030`, `GBK`, `GB2312`, `ISO-8859-1`, `ISO-8859-15`, `Windows-1252`.
Names are case-insensitive; aliases such as `latin1`, `latin9`, `cp1252`, `win1252`,
`iso_8859-15` and `utf8` are accepted. Any other name makes `read`/`write`/`edit`/`grep`
fail with an error naming the config file and the allowed values (no silent UTF-8 fallback).

### ISO-8859-1/-15 and Windows-1252

Example: a Latin-9 code base whose docs are UTF-8:

```json
{
  "sourceEncoding": "ISO-8859-15",
  "overrides": [{ "pattern": "docs/**", "sourceEncoding": "UTF-8" }]
}
```

- The configured single-byte encoding is applied directly; no auto-detection and no Python needed.
- ISO-8859-1 and Windows-1252 differ only in bytes `0x80`–`0x9F` (control characters vs.
  `€ „ “ ”` …). ISO-8859-15 replaces eight characters of ISO-8859-1, notably `€` at `0xA4`.
  Pick the one your files really use; `grep` (ripgrep) treats ISO-8859-1 as Windows-1252.
- Single-byte encodings cannot hold every character. Before writing, every character is
  checked; if one is not representable (e.g. `€` in ISO-8859-1, `“ ”` in ISO-8859-1/-15,
  emoji or CJK anywhere) **nothing is written** and the tool reports the characters, their
  line numbers and the encoding. Files are never silently changed to `?` or U+FFFD.
  Consequently, a Windows-1252 file containing the undefined bytes `81 8D 8F 90 9D` (read as
  U+FFFD) cannot be rewritten by the extension; the write is refused instead of corrupting them.

## Requirements

- A [Pi](https://github.com/earendil-works) agent (peer dependency; `>=0.80.0`).
- Encoding detection (for `read`/`write`/`edit`) uses Python 3 + `chardet` when available.
  If Python is missing, the extension silently falls back to `sourceEncoding` from config.
- `grep` uses [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) for fast,
  encoding-aware search. If `rg` is not found on `PATH`, `grep` transparently
  falls back to Pi's built-in grep (which cannot search inside legacy-encoded files).

## Install

From git (this fork, includes ISO-8859-1 / ISO-8859-15 / Windows-1252 support):

```bash
pi install git:github.com/msoftware/pi-encoding-fs
```

The `pi-encoding-fs` package on npm is the upstream release by 15wtyuan and only
supports GB18030 / GBK / GB2312:

```bash
pi install npm:pi-encoding-fs
```

## Notes / limitations

- Only `read` / `write` / `edit` / `grep` are overridden. `bash`, `find`, and `ls` are not
  touched (e.g. a `cat` inside `bash` won't decode GB files).
- `grep` shells out to `ripgrep` with `--encoding` per encoding group (derived from the
  nearest `.encoding-converter.json`), so searching Chinese inside GB18030 files is both
  correct and fast. It excludes `.git` / `.svn` / `.hg` / `node_modules` by default.
  Honoring `.gitignore` and aligning match limits with Pi's built-in grep are planned.
- `grep` decodes every file of a group with that group's encoding. A UTF-8 file inside a
  single-byte group (without a `UTF-8` override for its directory) is searched as
  single-byte text, so non-ASCII matches may be missed there.

### `edit` preview for GB-encoded files

Pi's `edit` tool reads the file in two places: `execute()` (via this extension's
encoding-aware `operations.readFile`, correct) and the TUI streaming _preview_
(`computeEditsDiff()`, which uses the built-in `readFile(path, "utf-8")` and bypasses
this extension). For a GB18030/GBK file the preview would read raw GB bytes as UTF-8
(mojibake), fail to match a Chinese `oldText`, and flash a false red
"Could not find the exact text in <path>" box during streaming — even though the real
edit succeeds.

This extension overrides `edit`'s `renderCall` so that non-UTF-8 files get an
encoding-aware preview instead: it reads through `operations.readFile`, computes the
diff with Pi's public `generateDiffString` + `renderDiff`, and renders a header that
matches Pi's native `edit` styling. UTF-8 files delegate to Pi's original renderer
unchanged.

Known trade-offs of this approach (no upstream change required):

- The preview uses **exact** `oldText` matching only (Pi's private fuzzy matcher isn't
  exported). If the model's `oldText` needs fuzzy normalization (trailing whitespace /
  smart-quote drift) the preview shows just the header, then the real edit runs and
  Pi's `renderResult` replaces it with the actual diff. GB files never get a false red
  error box anymore.
- The UTF-8 vs GB decision is a **byte-level** probe (`TextDecoder("utf-8",{fatal:true})`
  throws on GB bytes), mtime-cached. A single-byte legacy file (ISO-8859 /
  Windows-1252) with non-ASCII bytes is not valid UTF-8 and is routed through the
  encoding-aware preview, which reads through `operations.readFile` and therefore uses the
  configured encoding.

## Integration test

`scripts/Test-PiEncoding.ps1` runs the extension's tools against real files from
[Ousret/char-dataset](https://github.com/Ousret/char-dataset) and verifies the bytes on disk.
See [scripts/README.md](scripts/README.md).

## License

MIT
