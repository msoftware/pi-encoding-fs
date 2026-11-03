# pi-encoding-fs

[English](README.md) | **Deutsch**

Encoding-bewusstes `read` / `write` / `edit` / `grep` für [Pi](https://github.com/earendil-works).
Verarbeitet Dateien in GB18030 / GBK / GB2312 sowie ISO-8859-1 / ISO-8859-15 / Windows-1252
transparent und erhält dabei Pis native TUI (Diff-Ansicht, Syntax-Highlighting,
Zeilennummern).

> Dies ist der [msoftware-Fork](https://github.com/msoftware/pi-encoding-fs) von
> [15wtyuan/pi-encoding-fs](https://github.com/15wtyuan/pi-encoding-fs). Er ergänzt
> Unterstützung für ISO-8859-1, ISO-8859-15 und Windows-1252 (siehe [CHANGELOG](CHANGELOG.md)).

## Funktionsweise

Die Erweiterung registriert Tools mit denselben Namen wie Pis eingebaute Tools und ersetzt
diese damit. `read`/`write`/`edit` verwenden Pis eigene Tool-Gerüste über
`createXxxToolDefinition` und setzen die Encoding-Umwandlung nur auf der Byte-I/O-Ebene ein.
Pi berechnet und rendert Diffs dadurch weiterhin in UTF-8. `grep` ist selbst implementiert,
damit auch Nicht-ASCII-Text (Chinesisch, Umlaute, …) in Dateien mit Legacy-Encoding gefunden
wird.

Das Encoding wird **pro Datei** bestimmt: Die Erweiterung sucht vom Verzeichnis der Datei aus
aufwärts nach der nächstgelegenen `.encoding-converter.json`. Wird keine gefunden, wird die
Datei unverändert als UTF-8 durchgereicht (genau wie ohne installierte Erweiterung).

Außerdem hängt die Erweiterung einen kurzen Hinweis an den System-Prompt an. Der Agent weiß
dadurch, dass die eingebauten Tools die Umwandlung Legacy↔UTF-8 bereits erledigen (kein
`iconv`, kein erneutes Speichern nötig), und — falls noch keine Config existiert — wie er
selbst eine `.encoding-converter.json` anlegt, wenn er verstümmeltes Chinesisch oder kaputte
Umlaute liest. Der Hinweis ist konstant, damit Prompt-Caching wirksam bleibt.

## Konfiguration

Lege eine `.encoding-converter.json` in ein beliebiges Verzeichnis. Sie gilt für die Dateien
in diesem Verzeichnis und in allen Unterverzeichnissen, egal wie tief, sofern keine tiefer
liegende Config sie ersetzt.

Configs werden **nicht zusammengeführt**: Für jede Datei zählt nur die nächstgelegene Config.
Eine Config in einem Unterverzeichnis ersetzt die darüberliegende vollständig, einschließlich
`overrides`, `utf8Guard` und `confidenceThreshold` (nicht gesetzte Werte fallen auf die
eingebauten Standardwerte zurück, nicht auf die übergeordnete Config). Um einzelne Pfade ohne
zweite Config anders zu behandeln, verwende `overrides`.

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

- `sourceEncoding`: Standard-Encoding (wenn die GB-Erkennung unsicher ist); wird auch für neue
  Dateien verwendet.
- `confidenceThreshold`: minimale chardet-Konfidenz (0–1), ab der der automatischen Erkennung
  vertraut wird (nur GB).
- `utf8Guard` (Standard `true`): Bei einem Single-Byte-`sourceEncoding` wird eine Datei, die
  mit einem UTF-8-BOM beginnt oder vollständig gültiges UTF-8 mit Nicht-ASCII-Zeichen ist, als
  UTF-8 behandelt und als UTF-8 zurückgeschrieben. Mit `false` wird immer das konfigurierte
  Encoding angewendet.
- `overrides`: Glob-Regeln relativ zum Verzeichnis der Config-Datei; die spezifischste Regel
  gewinnt.

### Beispiel: ein ganzer Verzeichnisbaum in ISO-8859-1

Sind alle Dateien eines Verzeichnisses inklusive aller Unterverzeichnisse in ISO-8859-1
kodiert, genügt eine einzige Datei in diesem Verzeichnis:

```json
{ "sourceEncoding": "ISO-8859-1" }
```

- Weder `overrides` noch weitere Configs in Unterverzeichnissen sind nötig.
- Reine ASCII-Dateien sind nicht betroffen; dank `utf8Guard` bleiben Dateien, die bereits
  UTF-8 sind, UTF-8.
- Neue Dateien unterhalb dieses Verzeichnisses werden in ISO-8859-1 geschrieben.
- Nach dem Anlegen oder Ändern einer Config eine neue Pi-Session starten oder `/reload`
  ausführen.

### Unterstützte Encodings

`UTF-8`, `GB18030`, `GBK`, `GB2312`, `ISO-8859-1`, `ISO-8859-15`, `Windows-1252`.
Groß-/Kleinschreibung spielt keine Rolle; Aliase wie `latin1`, `latin9`, `cp1252`, `win1252`,
`iso_8859-15` und `utf8` werden akzeptiert. Jeder andere Name lässt `read`/`write`/`edit`/`grep`
mit einer Fehlermeldung scheitern, die die Config-Datei und die erlaubten Werte nennt (kein
stilles Zurückfallen auf UTF-8).

### ISO-8859-1/-15 und Windows-1252

Beispiel: eine Latin-9-Codebasis, deren Dokumentation in UTF-8 vorliegt:

```json
{
  "sourceEncoding": "ISO-8859-15",
  "overrides": [{ "pattern": "docs/**", "sourceEncoding": "UTF-8" }]
}
```

- Das konfigurierte Single-Byte-Encoding wird direkt angewendet; keine automatische Erkennung,
  kein Python nötig.
- ISO-8859-1 und Windows-1252 unterscheiden sich nur in den Bytes `0x80`–`0x9F`
  (Steuerzeichen vs. `€ „ “ ”` …). ISO-8859-15 ersetzt acht Zeichen von ISO-8859-1, vor allem
  `€` auf `0xA4`. Wähle das Encoding, das deine Dateien tatsächlich verwenden; `grep`
  (ripgrep) behandelt ISO-8859-1 als Windows-1252.
- Single-Byte-Encodings können nicht jedes Zeichen darstellen. Vor dem Schreiben wird jedes
  Zeichen geprüft; ist eines nicht darstellbar (z. B. `€` in ISO-8859-1, `“ ”` in
  ISO-8859-1/-15, Emoji oder CJK überall), wird **nichts geschrieben**, und das Tool meldet die
  Zeichen, ihre Zeilennummern und das Encoding. Dateien werden nie stillschweigend zu `?` oder
  U+FFFD verändert. Folglich kann eine Windows-1252-Datei mit den undefinierten Bytes
  `81 8D 8F 90 9D` (gelesen als U+FFFD) nicht von der Erweiterung neu geschrieben werden; das
  Schreiben wird verweigert, statt sie zu beschädigen.

## Voraussetzungen

- Ein [Pi](https://github.com/earendil-works)-Agent (Peer-Dependency; `>=0.80.0`).
- Die Encoding-Erkennung (für `read`/`write`/`edit`) nutzt Python 3 + `chardet`, falls
  vorhanden. Fehlt Python, fällt die Erweiterung stillschweigend auf `sourceEncoding` aus der
  Config zurück.
- `grep` nutzt [ripgrep](https://github.com/BurntSushi/ripgrep) (`rg`) für schnelle,
  encoding-bewusste Suche. Wird `rg` nicht im `PATH` gefunden, fällt `grep` transparent auf
  Pis eingebautes grep zurück (das nicht in Dateien mit Legacy-Encoding suchen kann).

## Installation

Aus Git (dieser Fork, inklusive ISO-8859-1 / ISO-8859-15 / Windows-1252):

```bash
pi install git:github.com/msoftware/pi-encoding-fs
```

Das Paket `pi-encoding-fs` auf npm ist das Upstream-Release von 15wtyuan und unterstützt nur
GB18030 / GBK / GB2312:

```bash
pi install npm:pi-encoding-fs
```

## Hinweise / Einschränkungen

- Nur `read` / `write` / `edit` / `grep` werden ersetzt. `bash`, `find` und `ls` bleiben
  unberührt (z. B. dekodiert ein `cat` innerhalb von `bash` keine GB-Dateien).
- `grep` ruft `ripgrep` mit `--encoding` pro Encoding-Gruppe auf (abgeleitet aus der
  nächstgelegenen `.encoding-converter.json`), sodass die Suche nach Chinesisch in
  GB18030-Dateien korrekt und schnell ist. `.git` / `.svn` / `.hg` / `node_modules` werden
  standardmäßig ausgeschlossen. Die Berücksichtigung von `.gitignore` und die Angleichung der
  Trefferlimits an Pis eingebautes grep sind geplant.
- `grep` dekodiert alle Dateien einer Gruppe mit dem Encoding dieser Gruppe. Eine UTF-8-Datei
  in einer Single-Byte-Gruppe (ohne `UTF-8`-Override für ihr Verzeichnis) wird als
  Single-Byte-Text durchsucht, sodass Nicht-ASCII-Treffer dort fehlen können.

### `edit`-Vorschau für GB-kodierte Dateien

Pis `edit`-Tool liest die Datei an zwei Stellen: in `execute()` (über das encoding-bewusste
`operations.readFile` dieser Erweiterung, korrekt) und in der _Vorschau_ der TUI während des
Streamings (`computeEditsDiff()`, das das eingebaute `readFile(path, "utf-8")` verwendet und
diese Erweiterung umgeht). Bei einer GB18030/GBK-Datei würde die Vorschau rohe GB-Bytes als
UTF-8 lesen (Zeichensalat), einen chinesischen `oldText` nicht finden und während des
Streamings fälschlich eine rote Box „Could not find the exact text in <path>“ anzeigen —
obwohl die eigentliche Bearbeitung gelingt.

Diese Erweiterung ersetzt deshalb `renderCall` von `edit`, sodass Nicht-UTF-8-Dateien eine
encoding-bewusste Vorschau erhalten: Sie liest über `operations.readFile`, berechnet den Diff
mit Pis öffentlichen Funktionen `generateDiffString` + `renderDiff` und rendert einen Header im
Stil von Pis nativem `edit`. UTF-8-Dateien werden unverändert an Pis ursprünglichen Renderer
weitergegeben.

Bekannte Kompromisse dieses Ansatzes (keine Änderung an Upstream nötig):

- Die Vorschau nutzt nur **exakten** Abgleich von `oldText` (Pis privater Fuzzy-Matcher wird
  nicht exportiert). Braucht der `oldText` des Modells eine Fuzzy-Normalisierung
  (abweichende Leerzeichen am Zeilenende / typografische Anführungszeichen), zeigt die
  Vorschau nur den Header; danach läuft die eigentliche Bearbeitung, und Pis `renderResult`
  ersetzt ihn durch den tatsächlichen Diff. GB-Dateien bekommen keine falsche rote Fehlerbox
  mehr.
- Die Entscheidung UTF-8 vs. GB ist eine **Byte-Prüfung** (`TextDecoder("utf-8",{fatal:true})`
  wirft bei GB-Bytes) mit mtime-Cache. Eine Single-Byte-Legacy-Datei (ISO-8859 /
  Windows-1252) mit Nicht-ASCII-Bytes ist kein gültiges UTF-8 und läuft daher über die
  encoding-bewusste Vorschau, die über `operations.readFile` liest und somit das
  konfigurierte Encoding verwendet.

## Integrationstest

`scripts/Test-PiEncoding.ps1` führt die Tools der Erweiterung mit echten Dateien aus
[Ousret/char-dataset](https://github.com/Ousret/char-dataset) aus und prüft die Bytes auf der
Festplatte. Siehe [scripts/README.md](scripts/README.md).

## Lizenz

MIT
