# stringsmith

**iOS localization from spreadsheets.**

English · [한국어](README.ko.md)

Teams keep translations in Google Sheets or Excel — Apple's XLIFF workflow is a machine format
that designers and PMs can't use. But the bridge from sheet to `.xcstrings` is usually an in-house
script with no validation, no round-trip, and no way to see the result.

stringsmith is that bridge, as a product.

```bash
ss init        # infer config from your sheet
ss generate    # write .xcstrings + typed Swift accessors
ss preview     # open the translation review app
```

## Install

### Download

Grab the latest from [Releases](https://github.com/keenkim1202/stringsmith/releases).
Universal binaries (Intel · Apple Silicon), macOS 13+.

| File | What |
|---|---|
| `StringsmithPreview-macOS.zip` | Translation review app |
| `stringsmith-macOS.tar.gz` | CLI |

```bash
# App — unzip into ~/Applications, then
xattr -dr com.apple.quarantine ~/Applications/StringsmithPreview.app

# CLI
tar -xzf stringsmith-macOS.tar.gz
sudo mv stringsmith /usr/local/bin/ && sudo ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss
xattr -dr com.apple.quarantine /usr/local/bin/stringsmith
```

> ⚠️ The builds are **unsigned**, so macOS blocks them on first launch. The `xattr` line above
> clears the quarantine flag. Code signing needs a paid Apple Developer account — not done yet.

### Build from source

```bash
git clone https://github.com/keenkim1202/stringsmith && cd stringsmith
make install        # CLI → /usr/local/bin/stringsmith (alias: ss)
make install-app    # App → ~/Applications/StringsmithPreview.app
```

`PREFIX=~/.local` and `APPDIR=/Applications` override the destinations. No `xattr` needed.

Two example sheets ship with the repo: `Examples/sample-sheet.csv` (a small tour) and
`Examples/edge-cases.csv` (parser, variable, and codegen corner cases — CI checks its output).

## Sheet format

| key | screen | description | ko | en |
|---|---|---|---|---|
| `settings.title` | Settings | Screen title | 설정 | Settings |
| `cart.itemCount` | Cart | Name and count | `{name}님의 상품 {count}개` | `{count} items for {name}` |

Column names differ per team, so they're **mapped** — `init` reads the header and drafts the
mapping for you.

- **Required:** a key column + at least one language column
- **Optional:** screen (namespace + comment), description (comment)
- Handles quoted commas/newlines, CRLF, BOM, blank rows, and a header row that isn't the first row

## What it generates

| Artifact | Output |
|---|---|
| `xcstrings` | `Localizable.xcstrings` — String Catalog |
| `swift` | `L10n.swift` — typed accessors |

```swift
Text(L10n.Cart.itemCount("Minsu", "3"))
Text(L10n.Settings.title)
```

Namespaces come from the key prefix (`order_cancel_confirm_body` → `L10n.Order.cancelConfirmBody`).
Swift keywords get backticks; name collisions get a suffix and a report.

> Apple's `xcstringstool generate-symbols` also generates accessors. Use it if that's enough —
> stringsmith differs by nesting namespaces, returning `String` (works below iOS 16), and putting
> the source value and comments into doc comments.

## Variables

Sheet notation is converted to iOS format specifiers. **The source locale assigns the positions,
and translations follow by name** — so word order can differ and the specifiers still line up.

| Sheet | Generated |
|---|---|
| `{name}님의 상품 {count}개` (ko, source) | `%1$@님의 상품 %2$@개` |
| `{count} items for {name}` (en) | `%2$@ items for %1$@` ← reordered automatically |

Translators never have to think about `%1$`/`%2$` — the part they break most often.

- Recognized notations: `{name}` (recommended), `%@`/`%d`/`%1$@`, `<count/>` (off by default).
  A sheet can mix them.
- **Every slot is `String` (`%@`).** A sheet can't tell you the type, and a wrong type corrupts
  values at runtime while `%@` accepts anything.
- Nested braces are fine — the **innermost pair** is the variable. For a literal brace, put a
  backslash before the opening one: `\{count}` → `{count}`.
- `\n` and `\t` become real control characters. `.xcstrings` is JSON, so leaving them as two
  characters would show `\n` on screen. This applies mid-word too — `C:\notes` becomes a line
  break followed by `otes`. A backslash is otherwise an ordinary character.
- `"50% off"` is not a variable. (`% o` is technically a valid printf specifier; localization
  strings never use it that way.)

Values are validated before anything is written — missing variables, extras that aren't in the
source, unnamed specifiers that can't survive reordering. **Every change is printed**, and
`-n` shows it before touching files.

## Preview app

A standalone macOS app that reads your sheet directly — no `generate` needed first.

```bash
ss preview     # opens the current project in the app
```

- **Multiple projects as tabs.** Run `ss preview` in another project and it joins the same window.
  Double-click a tab to rename, drag to reorder.
- **Refresh** (⟳ / ⌘R) re-reads the sheet after you edit it.
- All languages **side by side** — reviewing is comparing. Drag the language chips to reorder.
- **Variables are highlighted** in the rendered text, with fields to try sample values.
  Labels use the original names (`name`, `count`), not `arg1`.
- Toggles: *raw form* (see `{name}` before substitution), *with variables*, *missing only*
- Section tabs jump to that group. Window ▸ Always on Top (⇧⌘T).
- The app's own UI follows your system language (en · ko · ja).

## Commands

```bash
ss init [sheet]      # draft .stringsmith.json from the sheet header
ss generate          # write the artifacts
ss preview           # open in the review app
```

`init` finds the sheet (if exactly one CSV/TSV is in the folder), the header row, and the source
locale on its own. `.stringsmith.json` is found by walking up from the current directory, like git.

| Option | Command | Meaning |
|---|---|---|
| `-o` `--output` | init | Output directory (default `Resources`) |
| `-r` `--header-row` | init | Header row number, 1-based |
| `-s` `--source-locale` | init | Source locale |
| `--artifacts` | init | `xcstrings` · `swift` |
| `-f` `--force` | init | Overwrite an existing config |
| `-c` `--config` | all | Config path |
| `-n` `--dry-run` | generate | Show what would change, write nothing |
| `-v` `--verbose` | generate | Show every variable conversion |
| `--only` | generate | Override artifacts for this run |

## Configuration

```json
{
  "source":  { "path": "strings.csv", "headerRow": 2, "defaultLocale": "ko" },
  "columns": {
    "key": "키", "screen": "화면", "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": {
    "path": "Sources/Resources",
    "artifacts": ["xcstrings", "swift"],
    "tableName": "Localizable",
    "swift": { "enumName": "L10n", "namespace": "keyPrefix", "bundle": "main" }
  },
  "placeholders": { "syntax": ["apple", "brace"], "positional": "auto" }
}
```

Paths are relative to the config file, so it works from anywhere in the repo.

| Key | Values |
|---|---|
| `output.swift.namespace` | `keyPrefix` · `screen` · `none` |
| `output.swift.bundle` | `main` · `module` (SPM resources) |
| `placeholders.syntax` | `apple` · `brace` · `xml` |
| `placeholders.positional` | `auto` (positional only when 2+) · `always` · `never` |
| `placeholders.braceOpen` / `braceClose` / `escape` | Delimiters, default `{` `}` `\` |

## Design notes

- **Output is deterministic.** Same input, same bytes. Generated files get committed, so
  non-deterministic output would mean a merge conflict every run. Unchanged files aren't
  rewritten, avoiding needless rebuilds.
- **Empty translations are omitted.** Writing them as `translated` would hide the gap in Xcode.
- **`extractionState` is `manual`** so Xcode's auto-extraction doesn't mark sheet-owned keys stale.
- **File-level validation is left to others.** [LocaleLint](https://forums.swift.org/t/localelint-ci-validation-for-ios-localization-files-string-catalogs-xliff/86939)
  and [Locheck](https://github.com/irskep/locheck) check inside `.xcstrings` well; stringsmith
  validates the *sheet* side. Use both.

## Development

```
StringsmithCore      library — parsing, mapping, validation, generation. Returns data, never prints
stringsmith          CLI — thin wrapper (argument parsing + reporting)
StringsmithPreview   review app — links the core, reads sheets directly
```

```bash
make test       # 102 tests
make release    # universal distribution bundle → .build/dist
```

CI runs tests plus an end-to-end check (generate → Apple's compiler accepts it → accessors compile
→ second run changes nothing) on every push and PR. Pushing a `v*` tag cuts a release.

## License

Dual licensed under either of

- [Apache License 2.0](LICENSE-APACHE)
- [MIT license](LICENSE-MIT)

at your option. MIT is short and familiar; Apache-2.0 adds an explicit patent grant that some
organizations require. Unless you state otherwise, contributions you submit are dual licensed the
same way, with no additional terms.
