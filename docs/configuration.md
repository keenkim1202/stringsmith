# Configuration

English · [한국어](configuration.ko.md)

`.stringsmith.json`, found by walking up from the current directory. All paths are relative to
the file itself, so it works from anywhere in the repo.

`ss init` writes one for you. Most projects never touch the keys below the first table.

## source

| Key | |
|---|---|
| `type` | `csv` · `xlsx` · `google-sheets`. Detected from the extension too |
| `path` | The sheet file, for `csv` and `xlsx` |
| `url` | Google Sheets share URL |
| `gid` | A tab within that URL |
| `tabs` | Tabs to join. Google Sheets take a gid, or a name **once signed in**; Excel workbooks take a sheet name |
| `headerRow` | 1-based. Sheets often carry a title row above the header |
| `defaultLocale` | The source language. Becomes `sourceLanguage` in the catalog |

## columns

Maps your column names to what stringsmith needs. `init` infers these.

| Key | |
|---|---|
| `key` | The string key |
| `screen` | Optional. Used for the namespace and the comment |
| `description` | Optional. Becomes the comment |
| `languages` | Locale code → column name |

Columns you do not map are ignored, and `init` says which ones it skipped.

## output

| Key | |
|---|---|
| `path` | Where the localization files go |
| `artifacts` | `xcstrings` · `strings` · `stringsdict` · `swift` |
| `tableName` | Default `Localizable` |
| `pluralVariable` | The variable carrying the count. Default `count` |
| `swift.enumName` | Default `L10n` |
| `swift.namespace` | `keyPrefix` · `screen` · `none` |
| `swift.bundle` | `main` for an app target, `module` for SwiftPM resources |
| `swift.path` | Where the generated Swift goes, if not `output.path` |
| `swift.accessLevel` | `public` · `internal` |
| `swift.docComments` | Put the source value in a doc comment |

`swift.path` matters for Swift packages: SwiftPM takes everything under a `resources:`
directory, so an `L10n.swift` sitting beside the `.lproj` folders is copied as a resource
instead of compiled.

## placeholders

| Key | |
|---|---|
| `syntax` | Which notations to recognise: `apple` (`%@`) · `brace` (`{name}`) · `xml` |
| `positional` | `auto` (positional once there are two) · `always` · `never` |
| `braceOpen` / `braceClose` / `escape` | Delimiters. Default `{` `}` `\` |
| `numeric` | Variables to render as `%d`. Plurals set this themselves |

`syntax` is a list because real sheets mix notations — rows migrated from an older file carry
`%@` while new ones use `{name}`.

## validation

| Key | |
|---|---|
| `failOn` | Which warnings stop a build: `collision` · `missing` · `placeholder` · `key` · `whitespace` · `length` · `plural` · `other` |
| `keyPattern` | Regex keys must match. Unset means only structural checks |
| `lengthFactor` | Median multiple before a translation looks too long. Default `1.8`, `0` disables |

`failOn` defaults to `["collision"]`. Two keys becoming one Swift name is invisible afterwards —
nothing in the generated code says which is which, and deleting one from the sheet renames the
other. Missing translations deliberately do not fail: a sheet someone is still filling in always
has gaps, and iOS falls back to the source language.

An unknown name in `failOn` is ignored rather than raised. A typo in config should not stop a
build.

## Environment

| Variable | |
|---|---|
| `STRINGSMITH_LANG` | `en` or `ko`. Otherwise the CLI follows the system language |
| `STRINGSMITH_GOOGLE_CLIENT_ID` / `_SECRET` | Override `~/.config/stringsmith/client.json` |
| `NO_COLOR` | Turn colour off ([no-color.org](https://no-color.org)) |
| `FORCE_COLOR` · `CLICOLOR_FORCE` | Keep colour when piping, for CI logs |

Colour is off when the output is not a terminal, so `ss generate > log.txt` stays readable.
`NO_COLOR` wins over `FORCE_COLOR`.

## Full example

Signed in, so the tabs are named rather than listed by gid.

```json
{
  "source": {
    "type": "google-sheets",
    "url": "https://docs.google.com/spreadsheets/d/{ID}/edit",
    "tabs": ["common", "checkout"],
    "headerRow": 2,
    "defaultLocale": "ko"
  },
  "columns": {
    "key": "키",
    "screen": "화면",
    "description": "설명",
    "languages": { "ko": "한국어", "en": "영어", "ja": "일본어" }
  },
  "output": {
    "path": "Sources/App/Resources",
    "artifacts": ["strings", "stringsdict", "swift"],
    "swift": { "path": "Sources/App/Generated", "bundle": "module" }
  },
  "validation": { "failOn": ["collision", "missing"] }
}
```
