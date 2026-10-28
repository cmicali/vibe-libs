# third_party/Sparkle

[Sparkle](https://sparkle-project.org), the software update framework for macOS apps. Other authors' code: **do not restyle it.** It is macOS only, and it depends on nothing. Its template is `VibeLibsSparkle`. `system/Updates` lists it.

## What is vendored

**Sparkle 2.10.0, unmodified, as the prebuilt release.** It comes from the release tarball `Sparkle-2.10.0.tar.xz`, SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`, GitHub's own digest for the asset. Four things are kept: `Sparkle.framework` as shipped, its `LICENSE` as `LICENSE.txt`, and the tools `bin/sign_update` and `bin/generate_keys`. An app's release scripts run the tools to make its signing key and sign each update. The dSYMs, the test app, and the other tools are not vendored. Sparkle 2.10 needs macOS 12.0 or later.

## Building

**The template compiles nothing.** It adds the framework as a dependency of the app's target. That links it, embeds it in the product's `Frameworks`, and signs it there on copy, with the target's own identity. So the app needs `@executable_path/../Frameworks` in `LD_RUNPATH_SEARCH_PATHS`, as any app with an embedded framework does. Nothing in `bin/` or `LICENSE.txt` joins a project.

**TRAP: an app built locally with an ad hoc signature runs without the hardened runtime.** Under it, library validation refuses Sparkle in an ad hoc app, since the two have different Team IDs, and the app dies at launch. A distribution build turns the hardened runtime on and signs the app and the framework under one team. Notarization requires that.

**A configuration with no updater excludes the framework by name**, with `EXCLUDED_SOURCE_FILE_NAMES` (`system/Updates/AGENTS.md`). That unlinks and unembeds it.

## Updating

Replace the four kept files with the new tarball's, and record its version and digest here. Read its changelog for a raised minimum macOS. Then run the app's local update test: two builds signed with a throwaway key and a feed on `localhost`. The older build must install the newer one, from inside the sandbox if the app is sandboxed. `Tests/third_party/Sparkle/` only proves that the framework links and loads.

## License

MIT, in `LICENSE.txt`, with the notices of the four components it bundles: bsdiff 4.3 (BSD 2-clause), sais-lite (MIT), orlp/ed25519 (zlib), and `SUSignatureVerifier.m` (BSD 2-clause). `THIRD-PARTY-NOTICES.md` at the repo root has the notice.
