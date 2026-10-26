# tools/strings

An app's strings extraction and catalog checks. **It is scripts, not code an app compiles**, so it has no template and no targets. An app runs the scripts from its checkout of this repo and passes its own config file. It came from Vibe. The scripts run on a Mac with Xcode's command line tools and `jq`, under the system's bash 3.2.

| Script | What it does |
| --- | --- |
| `extract-strings.sh <config>` | Extracts the registry's keys into the catalog and derives the subset's catalog. |
| `extract-strings.sh <config> --check` | Fails when either catalog is out of date, or a translation's format specifiers differ from the English. Writes nothing. |
| `check-translations.sh <config>` | Fails when any key in any listed catalog is missing a catalog language. |
| `check-translations.sh <config> --github` | Warns instead, as GitHub annotations and a step summary. Exits 0. |
| `catalog-languages.sh <config>` | Prints the catalog's languages, one per line. No other list of an app's languages should exist. |

An app runs them from make targets of its own. Any script of the app's that needs the languages reads them from `catalog-languages.sh`.

## The registry

**Every user-facing string is one macro in one header, the registry.** Each entry is one line:

```objc
#define STR_MENU_FILE NSLS(@"menu.file", @"File", @"The File menu's title.")
```

`NSLS` expands to `NSLocalizedStringWithDefaultValue(key, nil, NSBundle.mainBundle, value, comment)`. The key is symbolic and stable. The value is the English, which becomes the catalog's `en` and the runtime fallback.

- **TRAP: the registry imports Foundation only under `#ifndef VIBE_STRINGS_EXTRACTION`.** `extract-strings.sh` runs the header through `clang -E` with that macro defined. Foundation would expand `NSLocalizedStringWithDefaultValue` itself, and extraction would find no keys.
- `xcstringstool` matches localization macros by name and arity, so it cannot read the three-argument `NSLS`. The script extracts from the preprocessed header instead, which fails loudly on a malformed entry.
- **The catalog is the `Localizable` table**, the one `NSLocalizedString` writes. Its file is named `Localizable.xcstrings`.
- Every other source under the config's source directories is swept too, so a stray inline `NSLocalizedString` cannot hide.
- A macro nothing references still yields a key. Delete the entry with its last call site.
- **One key has one default.** A key extracted with two values fails both modes, since `sync` would keep one and show it at the other's call sites.

## What extraction writes

- **Every live key is marked `extractionState: manual`.** TRAP: an Xcode build emits no `.stringsdata` for Objective-C. Its catalog pass would then mark every other key stale and write the marks into the checked-in catalog. `sync` skips manual keys too, so the script strips the marks, syncs, and marks again. A key whose entry was deleted comes through marked `stale`, and stays until it is deleted from the catalog.
- **English is promoted to `translated`.** The compiler emits `.strings` only for translated units, so without it an app ships no English table.
- **A reworded default replaces the English, and every other language becomes `needs_review`.** Those units still ship the old translation. A reword that changes the format specifiers needs a new key.
- **The subset is derived, never authored.** An app extension resolves strings against its own bundle. Its catalog is the keys under one prefix, copied from the main catalog. A subset source that names any other key fails, since it would fall back to English silently.
- **It is not a build phase.** Xcode has no build-time extraction for Objective-C, and a phase that rewrites a checked-in file dirties every build.

`check-translations.sh` tests for a key missing any catalog language, not for a key with only English. A key translated into a few languages to check layout must not pass. The languages are the union across the main catalog's keys. The subset is not listed there, since every key would report twice.

## The config file

**The config is a bash file the scripts source.** Every path in it is relative to `STRINGS_ROOT`, which is relative to the config file itself. A list is a bash array.

| Key | Required | Means |
| --- | --- | --- |
| `STRINGS_ROOT` | yes | The app's root, relative to the config file. |
| `STRINGS_REGISTRY` | yes | The registry header. |
| `STRINGS_MACROS` | yes | The registry's macro prefix. |
| `STRINGS_CATALOG` | yes | The main catalog, `Localizable.xcstrings`. Its keys set the languages. |
| `STRINGS_SOURCES` | yes | The directories swept for `.m`, `.mm`, and `.h` files. |
| `STRINGS_SKIP` | no | `find -path` patterns left out of the sweep. |
| `STRINGS_CATALOGS` | yes | Every catalog `check-translations.sh` covers, the main one included. |
| `STRINGS_UPDATE` | yes | The command that reruns extraction, which the messages name. |
| `STRINGS_GUIDE` | no | A line printed after the untranslated keys, pointing at the app's conventions. |
| `STRINGS_SUBSET` | no | The subset's name, as the messages name it. Unset, the subset keys below are not read. |
| `STRINGS_SUBSET_KEYS` | with a subset | The key prefix the subset carries. |
| `STRINGS_SUBSET_MACROS` | with a subset | The macro prefix of those keys. |
| `STRINGS_SUBSET_CATALOG` | with a subset | The subset's catalog. Its basename is the main catalog's, so the table keeps its name. |
| `STRINGS_SUBSET_SOURCES` | with a subset | The directories whose sources may name only the subset's keys. |

Vibe's config is `Resources/strings-config.sh` in its own repo:

```bash
STRINGS_ROOT=..

STRINGS_REGISTRY=Vibe/Common/VibeStrings.h
STRINGS_MACROS=STR_
STRINGS_CATALOG=Resources/Localizable.xcstrings
STRINGS_SOURCES=(Vibe)
STRINGS_SKIP=('*/ThirdParty/*' '*/Debug/*')
STRINGS_CATALOGS=(Resources/Localizable.xcstrings Resources/InfoPlist.xcstrings Resources/ThemeNames.xcstrings)
STRINGS_UPDATE='make strings'
STRINGS_GUIDE='The vibe-strings skill has the register, quote and terminology conventions.'

STRINGS_SUBSET=widget
STRINGS_SUBSET_KEYS=widget.
STRINGS_SUBSET_MACROS=STR_WIDGET_
STRINGS_SUBSET_CATALOG=VibeWidget/Localizable.xcstrings
STRINGS_SUBSET_SOURCES=(VibeWidget Vibe/iOS/Widget)
```

## What stays in each app

The registry, the catalogs, the config, and the translations are the app's. So are its conventions for wording and translating.

## The self-test

`make test-strings` runs `Tests/tools/strings/strings-test.sh`. Each case copies `Tests/tools/strings/Fixture/`, a tiny app with a registry, a source, a skipped directory, an extension, two catalogs in English and German, and a config. It runs the scripts there and checks the exit status and the message. The cases cover a clean pass, a byte-identical rewrite, a new key, a reword, two defaults, a lost specifier, a stray extension key, a stale subset, a config with no subset, and GitHub mode. CI runs it. A change to a script gets a case.

**TRAP: `extract-strings.sh` checks for a macro of the config's prefix before it lists them.** Under `pipefail` an empty `grep` stops the script, so an error placed after it can never print. The self-test pins the message.
