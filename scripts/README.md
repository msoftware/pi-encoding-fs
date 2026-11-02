# Integration test against real legacy-encoded files

`Test-PiEncoding.ps1` (PowerShell) and `harness.ts` run the extension's real tools
(`read`, `edit`, `write`, `grep`) against files from
[Ousret/char-dataset](https://github.com/Ousret/char-dataset) and verify the bytes that end
up on disk. No language model is involved: the registered tools are called directly, so the
run is deterministic.

This complements the unit tests in `test/` (`npm test`), which use small synthetic fixtures.

## Requirements

- `git`, Node.js >= 18, `npm`
- PowerShell 5.1 (Windows) or PowerShell 7+ (Windows, Linux, macOS)
- optional: [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) on `PATH`; without it the
  `grep` checks are skipped

## Run

Both files must stay in the same folder.

```powershell
.\scripts\Test-PiEncoding.ps1
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Branch` | `main` | Branch of `msoftware/pi-encoding-fs` to test |
| `-WorkDir` | `scripts\work` | Where clones and run folders are created (git-ignored) |

```powershell
.\scripts\Test-PiEncoding.ps1 -Branch main -WorkDir C:\temp\pi-enc-test
```

If script execution is blocked on Windows, allow it for the current session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## What the script does

1. Clones `msoftware/pi-encoding-fs` (the same code `pi install git:github.com/msoftware/pi-encoding-fs`
   installs) into `<WorkDir>\pi-encoding-fs` and runs `npm install`. It tests that clone, not the
   checkout you started the script from.
2. Clones `Ousret/char-dataset` with `core.autocrlf=false`. This matters on Windows: with
   autocrlf, git would rewrite line endings inside the legacy-encoded files and corrupt the test data.
3. Creates a fresh run folder `<WorkDir>\runs\<timestamp>` with copies of sample files and one
   `.encoding-converter.json` per sub-folder:

   | Folder | Config | Content |
   | --- | --- | --- |
   | `iso8859_1` | `ISO-8859-1` | 6 French/Spanish/Finnish/... text files |
   | `windows_1252` | `cp1252` (alias) | 5 files incl. a 213 KB HTML file |
   | `gb18030` | `GB18030` | 2 Chinese files (regression check) |
   | `utf_guard` | `latin1` | 3 UTF-8 files, to exercise `utf8Guard` |
   | `plain` | none | the same UTF-8 files; reference for stock Pi behaviour |
   | `cp1250` | `windows-1250` | unsupported encoding, must fail with a clear error |
   | `iso8859_15` | `ISO-8859-15` | empty, used for newly created files |

4. Runs `harness.ts` (via `vite-node`, from inside the extension clone so Pi's packages resolve).

## What is checked

For every file in the first four folders:

- **read** returns clean UTF-8 (no U+FFFD) containing the expected non-ASCII word
- **grep** finds that word
- **edit** appends a marker next to the first non-ASCII character; the file grows by exactly
  the 6 marker bytes and decodes to the expected text (an independent `TextDecoder`, not
  `iconv-lite`, is the reference); in `utf_guard` the result must stay valid UTF-8 and be
  byte-identical to Pi's own `edit` without the extension
- **write** rewrites the whole file; the result must equal the previous bytes plus `ZZZ`

Additionally:

- writing `€` into an ISO-8859-1 file is refused and the file stays byte-identical
- new files get the right bytes (`A4` for `€` in ISO-8859-15, `84 93 80` for `„ “ €`
  in Windows-1252, `FC DF` for `ü ß` in ISO-8859-1)
- an unsupported encoding (`windows-1250`) reports a clear error listing the supported ones

## Reading the output

| Marker | Meaning |
| --- | --- |
| `PASS` | check succeeded |
| `FAIL` | check failed; the script exits with code 1 |
| `KNOWN` | documented limitation, not counted as failure: `grep` decodes a whole folder with its configured encoding, so non-ASCII text in UTF-8 files inside a single-byte folder is not found (see the main README) |
| `SKIP` | not applicable, e.g. a UTF-8 file with a BOM and ASCII-only content has nothing to edit |

Expected result against `main`: no `FAIL`, two `KNOWN` (both in `utf_guard`), one `SKIP`.
The run folder is kept, so you can inspect the resulting files, e.g.

```powershell
Format-Hex -Path .\scripts\work\runs\<timestamp>\iso8859_1\_ude_2.txt | Select-Object -First 8
```

## Trying it with a real agent (optional)

The script does not need a model. To try the extension by hand in Pi with a model of your choice:

```bash
pi install git:github.com/msoftware/pi-encoding-fs
cd scripts/work/runs/<timestamp>/iso8859_1
pi
```

Ask the agent to read and edit `_ude_2.txt`, then inspect the bytes with `Format-Hex` as above.
Small local models call tools less reliably than the direct tool calls the script makes.

## Troubleshooting

- **`'node' wurde nicht gefunden`** (or git/npm): install the missing tool and restart the shell.
- **`vite-node` or npm errors**: delete `<WorkDir>\pi-encoding-fs\node_modules` and run again.
- **Many `FAIL` on read/edit in `iso8859_1`/`windows_1252` right at the start**: check that the
  dataset was cloned with `core.autocrlf=false` (the script does this; a dataset you cloned
  yourself into `<WorkDir>\char-dataset` may have been converted).
- **No network / proxy**: the script needs access to `github.com` and the npm registry.
