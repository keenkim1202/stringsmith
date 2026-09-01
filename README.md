# stringsmith

**iOS localization from spreadsheets.**

English · [한국어](README.ko.md) · [Changelog](CHANGELOG.md)

Teams keep translations in Google Sheets or Excel — Apple's XLIFF workflow is a machine format
that designers and PMs can't use. But the bridge from sheet to `.xcstrings` is usually an in-house
script with no validation, no round-trip, and no way to see the result.

stringsmith is that bridge, as a product.

## The shape of it

One row in a sheet:

| key | screen | ko | en |
|---|---|---|---|
| `cart.greeting` | 장바구니 | `{name}님의 장바구니` | `{name}'s cart` |

becomes a String Catalog entry and this:

```swift
Text(L10n.Cart.greeting(customer))
```

The parameter is there because the sheet says so. Remove `{name}` from the sheet and the call
site stops compiling — that is the whole point.

## Install

```bash
brew install keenkim1202/tap/stringsmith
```

That is the CLI: `stringsmith`, and `ss` as a short alias. Universal binary, macOS 13+.

The review app is a separate download and only `ss preview` needs it. Take
`StringsmithPreview-macOS.zip` from
[Releases](https://github.com/keenkim1202/stringsmith/releases):

```bash
unzip StringsmithPreview-macOS.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/StringsmithPreview.app
```

The app is unsigned, which is what the `xattr` line clears.

Without Homebrew, take `stringsmith-macOS.tar.gz` from the same page:

```bash
tar -xzf stringsmith-macOS.tar.gz
sudo mv stringsmith /usr/local/bin/ && sudo ln -sf /usr/local/bin/stringsmith /usr/local/bin/ss
xattr -dr com.apple.quarantine /usr/local/bin/stringsmith
```

Or from source: `make install` (CLI) and `make install-app` (the review app). No `xattr` needed.

## Use

```bash
ss init        # write .stringsmith.json from your sheet's header
ss generate    # write the artifacts
```

`init` finds the sheet, the header row and the source language on its own. Review the config it
writes, then generate. `.stringsmith.json` is found by walking up from the current directory,
like git.

| Command | |
|---|---|
| `ss init [sheet]` | Draft a config. `--url` for Google Sheets, `--format` to pick an output format |
| `ss import <path>` | Draft a sheet from `.xcstrings` or `.lproj` files you already have |
| `ss generate` | Write the artifacts. `-n` to preview, `--only` to narrow |
| `ss validate` | Check the sheet, write nothing. `--strict` for CI |
| `ss drift` | Find keys the sheet and the code disagree on |
| `ss preview` | Open the review app |
| `ss auth login` | Sign in to Google for private sheets |

`--help` lists every flag. `ss` and `stringsmith` are the same binary.

### Coming from files you already have

Every other command assumes the sheet exists. If your translations are still in `.xcstrings` or
`.lproj` files, that is what `import` is for:

```bash
ss import Sources/Resources        # or path/to/Localizable.xcstrings
ss init strings.csv
```

One row per key, one column per language, and `/* comments */` become a `description` column.
Plurals arrive as key suffixes (`cart.items.one`), which is how the sheet writes them.

Variables come back as `{arg1}`, `{arg2}`. The files record where a variable sits, never what it
held, so rename them in the sheet before you generate. The counting variable in a plural keeps
the name `count`: `.stringsdict` has to see an integer there to pick a category at all.

## Sources

CSV, TSV and `.xlsx` are read from disk — point at the file or let `init` find it. Excel needs no
extra dependency; number formats are not interpreted, so a date-formatted cell arrives as its
serial number.

Google Sheets are read from the share URL:

```bash
ss init --url "https://docs.google.com/spreadsheets/d/{ID}/edit#gid=0"
```

Public links work as-is. For a sheet that needs sign-in, run `ss auth setup` — it creates the
OAuth client file and prints the five console steps to fill it in — then `ss auth login`. After
that, any sheet your account can open is readable without changing its sharing settings. The
last good response is cached — signed in or not, and joined tabs included — so being offline
does not stop a build. A sheet that stops being *readable* is a different thing and does fail:
a stale cache would hide it for months.

Sheets split across tabs join with `"tabs": ["common", "checkout"]`. Names need a sign-in —
resolving one takes the API — so a public link lists gids instead.

## Output

Pick one format; they are alternatives, not a pair.

| | |
|---|---|
| `xcstrings` (default) | One `Localizable.xcstrings`, all languages |
| `strings` | `<locale>.lproj/Localizable.strings`, plus `.stringsdict` for plurals |

```bash
ss generate --format strings
```

Typed Swift accessors are generated either way. **SwiftPM does not compile String Catalogs** — a
Swift package has to ship `strings`; an app target in an Xcode project can use either.

### Variables

Write `{name}` in the sheet. It becomes `%@`, or `%1$@` when there is more than one, so a
translation can reorder them. `\{name}` is a literal brace, and `%` next to a variable is escaped
for you.

Every slot is a `String`. The sheet cannot say what type a value is, and a wrong guess breaks at
runtime while `%@` accepts anything.

### Plurals

Written as key suffixes — `cart.items.one`, `cart.items.other`, using the CLDR categories. Both
formats carry them properly and the accessor is one function taking an `Int`:
`L10n.Cart.items(3)`. Which form to show is iOS's job, not the call site's.

## Checking

`generate` stops on anything that would produce wrong output: a duplicate key, an empty source
value, a variable the source does not have, or two keys colliding into one Swift name. Everything
else warns and names the key and row.

```
⚠️ ja: 3/100 translations missing
     missing.ja_only (row 98)
```

`validation.failOn` decides which warnings stop a build. Missing translations deliberately do
not — a sheet someone is still filling in always has gaps.

`ss drift` covers what compiling cannot: keys nobody uses, and keys called by string
(`NSLocalizedString`) that the sheet lacks.

### CI

`validate` checks the sheet. `git diff` catches the PR that edited the sheet and forgot to
regenerate. Generated files are committed, so both belong in the same job.

```yaml
- run: ss validate --strict
- run: ss generate
- run: git diff --exit-code    # sheet edited, artifacts not regenerated
```

Failures are told apart by exit code, so a script can branch on them:

| | |
|---|---|
| `0` | passed |
| `2` | the config or the sheet could not be read. Someone has to fix the config. |
| `3` | the sheet was read, its contents failed validation. Someone has to fix the sheet. |
| `64` | wrong command or flag |

## Preview app

A macOS app that reads the sheet directly, no `generate` first. All languages side by side,
variables highlighted with fields to try values, refresh after an edit, and one tab per project.

```bash
ss preview
```

## Configuration

```json
{
  "source":  { "path": "strings.csv", "headerRow": 2, "defaultLocale": "ko" },
  "columns": {
    "key": "키", "screen": "화면", "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": { "path": "Sources/Resources", "artifacts": ["xcstrings", "swift"] }
}
```

Paths are relative to the config file. The full key list is in [docs/configuration.md](docs/configuration.md).

## Notes

- **Output is deterministic** and unchanged files are not rewritten. Generated files get
  committed, so a run that reshuffles them would mean a merge conflict every time.
- **Empty translations are omitted** rather than written as `translated`, which would hide the
  gap in Xcode.
- **File-level validation is left to others.**
  [LocaleLint](https://forums.swift.org/t/localelint-ci-validation-for-ios-localization-files-string-catalogs-xliff/86939)
  and [Locheck](https://github.com/irskep/locheck) check inside `.xcstrings`; stringsmith checks
  the sheet. Use both.

## Example

[`Examples/DemoApp`](Examples/DemoApp) is a sheet, a config and a SwiftUI app that runs, with its
generated files committed so you can read them.

## Development

```bash
swift build && swift test
python3 Scripts/run-ci.py    # every CI check, locally
make release                 # universal binaries + app bundle
```

## License

Apache-2.0 or MIT, at your option.
