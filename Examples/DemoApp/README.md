# DemoApp

A sheet, a config, and an app that runs — the whole path in one place.

```bash
swift run DemoApp                       # the window
swift run DemoApp -- --dump             # strings only, system language
swift run DemoApp -- --dump --lang ja   # strings only, one language
```

## What is here

| | |
|---|---|
| `strings.csv` | 10 keys × 3 languages. Edit this |
| `.stringsmith.json` | The config |
| `Sources/DemoApp/L10n.swift` | Generated. Committed on purpose — read it |
| `Sources/DemoApp/Resources/*.lproj/` | Generated |
| `Sources/DemoApp/ContentView.swift` | The app. No string literals, no key names |

Change a translation and regenerate:

```bash
stringsmith generate
swift run DemoApp -- --dump
```

## What it demonstrates

`ContentView.swift` has no key strings in it. `L10n.Cart.greeting(customer)` takes a
parameter because the sheet says `{name}` is in that value — remove the variable from the
sheet and the call site stops compiling, which is the point.

Plurals go through one accessor: `L10n.Cart.items(3)`. The sheet has `cart.items.one` and
`cart.items.other`; picking between them is iOS's job. Korean has only `other`, so `--lang ko`
prints the same form for 1 and 3 — that is correct, not a bug.

`cart.discount` carries a literal `%` next to a variable, which is where hand-written format
strings usually break.

## Two things this example pinned down

**SwiftPM does not compile String Catalogs.** Putting a `.xcstrings` in `resources:` copies it
verbatim, and every lookup falls back to the key — the app shows `cart.title` on screen. Xcode
projects compile catalogs as a build step; SwiftPM does not. So a package ships
`--format strings`, which is what this example uses. An app target in an Xcode project can use
either.

**Generated code and resources cannot share a directory.** `.process("Resources")` takes
everything under it, so an `L10n.swift` sitting next to the `.lproj` folders is copied as a
resource instead of compiled. `output.swift.path` puts it elsewhere.

## Language switching

`--lang` opens one `.lproj` directly, which is what a QA screen does. It does not go through
`L10n`, since the generated code holds a fixed bundle.

In a real app you would change the language in Xcode's scheme (Run → Options → App Language)
rather than in code. `-AppleLanguages` on the command line has no effect on a bare SwiftPM
executable — the argument domain is not consulted, so `--lang` exists here instead.
