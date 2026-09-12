# openjdk feedstock

OpenJDK (Eclipse Temurin JRE) as a tebako **runtime** — the hermetic
`java` engine (spec 28/29): the release ships the pair per platform, the
tebako-owned wrapper exe (`tebako-runtime-launcher`, the process entry
point) plus the env image (`.tfs`, mounted — never extracted).

- **kind:** runtime (`engine: java`, `implementation: temurin`)
- **upstream:** Temurin JRE 21.0.12+8 (Adoptium), repacked — no compilation
- **artifacts:** `tebako-runtime-<tebako-line>-21.0.12-<platform>[.exe]`
  + `.tfs` + `.sha256` sidecars + `<stem>.manifest.json` release shards
  (+ a detached `.asc` per served name on signing-enabled lines), and
  this registry (`tpkg-registry.yaml`) on the repo's default branch
- **visibility:** `exec-cache` (spec 29 §3) with the link-unit preload
  shim granted on POSIX (the jail survives the exec into the JVM)

Consumers' app payloads declare
`runtime_requirement: {engine: java, constraint: ">= 21"}` on their
entrypoints; the dispatcher resolves the newest compatible cached
runtime (or downloads + verifies it from this repo's release index).

> The spec-30 dispatch surface for a runtime's OWN entries
> (`tebako run openjdk:java`, shimmed `java`) is PLANNED product-side.
> Until it lands the JRE's tools are declared in the runtime manifest's
> additive entrypoints list (the registry carries no entrypoints on
> kind: runtime) and the interpreter answers the spec 17 wire directly
> (`--tebako-entry java …` on the wrapper exe).

Toolkit era: pre-promotion this repo shipped `kind: toolkit` payloads
(`openjdk-21.0.12-<platform>.tfs`, tags like `21.0.12-2`). Runtime
release tags follow the trr convention `v<tebako-line>` (the tag IS the
tebako line the pair builds against).

## Release shape (spec 13 §2a — the de-rendezvous, roadmap 85)

On a tag, each build leg **publishes and signs in-leg**: the leg that
built a pair uploads only the write-once names it owns (the wrapper exe,
the `.tfs` env image, both `.sha256` sidecars, the
`<stem>.manifest.json` shard) and — when `TEBAKO_RELEASE_SIGNING_ENABLED`
is armed — signs every one of those served names itself (spec 09 §5's
no-fold rule: nothing is ever "covered by" another artifact's signature;
the shard declares each artifact's `{keyid, asc}` block from the
`TEBAKO_RELEASE_SIGNING_KEYID` repo variable). No shared mutable file
exists, so all six legs (2 flavors × 3 platforms) publish concurrently
with zero rendezvous.

There is **no monolithic `manifest.json` / `SHA256SUMS.txt` release
asset**: both are derivable conveniences, computed consumer-side from
the shards + the asset listing (`tebako-pkg release-index`). The release
notes are written once at release creation (by whichever leg wins the
create race) and never rewritten. Every asset name is write-once: a
re-run skips digest-matching names and loudly keeps differing ones — a
bad published artifact is remedied by `status: withdrawn` in the
registry (spec 04 §2) plus the next patch line, never by
delete-and-replace.

The single `release` job then keeps only the two whole-matrix duties:

1. **Audit** (`tools/audit_release.rb`, read-only) — the expected
   (flavor × platform) matrix, derived from the workflow's own build
   matrix × `recipe.yml`'s pins, must be a subset of the release
   listing; on signing-enabled lines every served name's `.asc` is
   required, and the retired monoliths are refused.
2. **Registry** (`tools/registry_update.rb`) — renders
   `tpkg-registry.yaml` from the release's shards (never from
   templates) and lands it on `main` by bot PR. The merge preserves
   existing versions' rows and any `status: withdrawn` marks;
   `default:` tracks the newest non-withdrawn version.

Tooling specs live in `spec/` (`sign_release_spec.rb`,
`audit_release_spec.rb`, `registry_update_spec.rb`) and run in the lint
workflow.
