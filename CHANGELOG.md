# Changelog

English · [한국어](CHANGELOG.ko.md)

## Unreleased

- **`ss import` no longer chokes on files it did not write.** A device variation used to fail
  the whole catalog, since one unreadable key stopped every other key from being read.
  `%#@…@` substitutions used to come out as `{arg1}count@`, which looks plausible enough to
  survive review. Both are now named and skipped. `.strings` tables other than `Localizable`
  are named too, and `--table` reads one of them.

## 0.3.0

The one behaviour change to know about: **failures no longer all exit `1`.** A CI script that
branches on exit code 1 needs updating, and the table under "Checking" in the README says what
replaced it.

- **`ss import` reads what you already have.** Point it at a `.xcstrings` file or at the
  directory holding your `.lproj` folders and it writes the sheet: one row per key, one column
  per language, comments in a `description` column, plurals as key suffixes. Until now every
  command assumed the sheet existed, which left an app with 300 strings copying them by hand.
  Variables come back as `{arg1}`: the files record where one sits, never what it held.
- **Homebrew.** `brew install keenkim1202/tap/stringsmith` installs the CLI and its `ss` alias,
  and `brew upgrade` keeps it current. No `xattr` step: the quarantine flag is only set on
  files a browser downloaded. The release workflow updates the formula, so the tap cannot fall
  behind a release.
- **Exit codes tell failures apart.** `2` means the config or the sheet could not be read, `3`
  means the sheet was read and its contents failed validation. Everything used to exit `1`, so a
  CI script could not tell "fix the config" from "fill in the sheet". The README has the table
  and a CI recipe.
- **The offline warning says how old the cache is** (`using the cached copy (12 days ago)`).
  Without it a months-old cache builds quietly.

## 0.2.0

Everything below is new since the first release. If you are on 0.1.0, the one behaviour change
to know about is that **a Swift name collision now stops `generate`** instead of only warning —
see `validation.failOn` if you need the old behaviour.

### Sources

- **Google Sheets by URL.** `ss init --url …` reads the sheet directly; no CSV export step.
  The last good response is cached, so being offline does not stop a build.
- **Sign-in for private sheets.** `ss auth login` opens a browser once (PKCE, loopback). Any
  sheet your account can open becomes readable without loosening its sharing settings. The
  OAuth client is yours, not bundled — `ss auth setup` writes the file to fill in.
- **Excel.** `.xlsx` reads directly, no dependency added.
- **Several tabs** join into one table with `source.tabs`.

### Output

- **`--format`** picks between String Catalogs and `.strings`/`.stringsdict`.
- **Plurals**, written as key suffixes (`cart.items.one`). Both formats carry them properly, and
  the generated accessor is one function taking an `Int`.
- **`output.swift.path`** puts generated code somewhere other than the resources directory.

### Checking

- **`ss validate`** checks the sheet without writing anything. `--strict` for CI.
- **`ss drift`** finds keys the sheet and the code disagree on — unused ones, and ones called by
  string that the sheet lacks.
- **`validation.failOn`** decides which warnings stop a build. Name collisions do by default.
- New rules: key names, invisible characters, plural categories against CLDR, and translations
  far longer than the rest of their language.

### Fixes

- Leading and trailing spaces in translations are kept — they can be deliberate.
- Rows whose source cell is legitimately empty (a plural form the source language lacks) are no
  longer reported as missing, and their translations are converted rather than shipped raw.
- Errors name the tab a row came from when tabs are joined.
- `--header-row` had no short option: its derived `-h` collided with `--help`. It is `-r`.

## 0.1.0

First release. CSV and TSV in, `.xcstrings` and typed Swift accessors out, with the variable
notation converted to iOS format specifiers and a macOS app for reviewing the result.
