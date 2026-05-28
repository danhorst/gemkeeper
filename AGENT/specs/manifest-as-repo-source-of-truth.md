# Spec: Manifest as Source of Truth for Repo URLs

## Status

Accepted

## Problem

`gemkeeper.yml` currently stores both `name:` and `repo:` for each gem entry.
The manifest (`~/.config/gemkeeper/manifest.yml`) also stores `name → repo` mappings — by design, as the global lookup table shared across projects.
This is two sources of truth for the same fact.

When a repo is renamed, both the manifest and every per-project `gemkeeper.yml` must be updated.
The v0.6.7 fix introduced explicit `name:` fields in generated entries so that `merge` could match by name rather than by repo URL basename, which is an improvement.
But the underlying redundancy remains: `repo:` in `gemkeeper.yml` duplicates what the manifest already knows.

## Proposed Change

Make `repo:` optional in `gemkeeper.yml` gem entries.
When `repo:` is absent, resolve it from the manifest at sync time using the entry's `name:`.
`ConfigGenerator` (`setup` and `manifest generate`) stops writing `repo:` in new entries.

### Before

```yaml
# gemkeeper.yml
gems:
  - name: my-gem
    repo: git@github.com:company/whatever-the-repo-is-called.git
    version: latest
```

### After

```yaml
# gemkeeper.yml
gems:
  - name: my-gem
    version: latest

# manifest.yml (single place repo URL lives)
gems:
  - name: my-gem
    repo: git@github.com:company/whatever-the-repo-is-called.git
```

A repo rename then requires updating the manifest once.
No per-project `gemkeeper.yml` changes are needed.

### Name and repo resolution

A gem entry must yield both a `name` and a `repo`:

- `name:` present → use it; resolve `repo:` from the manifest by name when `repo:` is absent.
- `name:` absent, `repo:` present → derive the name from the repo basename (today's behavior in `GemDefinition#extract_name_from_repo`).
- both absent → `InvalidConfigError`.

`GemDefinition#initialize` currently raises when `repo` is missing.
It must be reworked so a missing `repo` is valid when `name` is present, with the lookup deferred to sync time.

## Design Decisions

### Where does manifest lookup happen?

Three options:

| Layer           | Pros                                              | Cons                                                         |
| --------------- | ------------------------------------------------- | ------------------------------------------------------------ |
| `Configuration` | `GemDefinition` objects are fully resolved early  | `Configuration` gains a new dependency on `ManifestReader`   |
| `GemSyncer`     | Lookup stays close to where repo is used          | `GemSyncer` needs a manifest passed in; callers change       |
| `GemDefinition` | Encapsulated; callers unchanged                   | Lazy resolution; manifest must be injected or found globally |

**Decision**: resolve at sync time, in `Sync`/`GemSyncer` — the `GemSyncer` row above.
`GemDefinition#repo` is consumed *only* by `GemSyncer`; `list`, `server start/stop/status`, and `version` never read it.
Resolving in `Configuration.load` would couple every command to the manifest and its failure modes — a missing or broken manifest could break `gemkeeper server start`.
Sync-time resolution confines the manifest dependency to the one path that uses it.
`GemDefinition` stays a plain value object with a possibly-`nil` `repo`; the syncer fills it from the manifest by name.

### The `--manifest` flag for `sync`

`setup` and `manifest generate` both accept `--manifest` to override the manifest path.
If `sync` now implicitly reads the manifest, it also needs this option — or the manifest path must be derivable from the config file.

Options:
- Add `--manifest` to `sync` (and eventually all commands that touch the manifest).
- Store the manifest path in `gemkeeper.yml` (e.g. `manifest: ~/.config/gemkeeper/manifest.yml`) so a single config file controls everything.
- Always use the default manifest path for `sync`; only `setup`/`generate` need the override.

The third option is simplest and probably sufficient.
`sync` is a runtime operation; `setup` is configuration time.
Users who need a non-default manifest path for syncing are an edge case.

### Conflict resolution

If a `gemkeeper.yml` entry has an explicit `repo:` AND the manifest has a different URL for the same gem name, which wins?

**Decision**: the explicit `repo:` in `gemkeeper.yml` wins, but sync warns when it diverges from the manifest.
A silent override is exactly the kind of drift this spec exists to kill, and `ManifestReader#add_mapping` already treats a name mapping to two repos as a hard error (`ManifestConflictError`).
Warning keeps the override available as a deliberate escape hatch while surfacing the divergence.
A user who updates the manifest and wants `gemkeeper.yml` to follow must re-run `setup` or remove the `repo:` field manually.

### Error handling

When `repo:` is absent and the manifest lookup fails, the error should be specific:

- Manifest file not found → `"No manifest found at <path> — run 'gemkeeper manifest generate' to create one"`
- Gem name not in manifest → `"No repo configured for 'my-gem' — add it to the manifest with 'gemkeeper manifest generate'"`

### Escape hatch: gems not in the manifest

Some repos may not warrant a manifest entry: one-off forks, gems used by only one project, temporary overrides.
Keeping `repo:` as a supported (but non-generated) field preserves this.
These entries continue to work unchanged.

## Trade-offs

### What this change improves

- Repo renames require updating one file (the manifest) instead of N project files.
- `gemkeeper.yml` is leaner and expresses only per-project concerns (which gems, which versions).
- The manifest fulfills its stated design purpose as the authoritative name→repo table.

### What this change costs

**The manifest becomes a required input for `sync`.**
`gemkeeper.yml` is intentionally local-only; the manifest is the shareable artifact, distributed to seed a machine's name→repo table.
This is the point of the change rather than a cost: projects stay local, and the manifest travels.
A machine needs the manifest present before `sync` can resolve repo-less entries.
`gemkeeper manifest validate` becomes a useful pre-flight check.

**Scope of the dependency is `sync` only.**
Because resolution happens at sync time, `server`, `list`, `status`, and `version` are unaffected — they never read `repo` and never load the manifest.

**`setup <gemkeeper.yml>` repo-import becomes vestigial.**
`update_manifest_from_config` extracts `repo:` entries from a `gemkeeper.yml` into the manifest.
Generated files no longer carry `repo:`, so this path no longer seeds the manifest for them.
With no existing users to support, it can be removed rather than maintained.

## Migration

No real users exist yet, so there is no migration burden and no back-compat to preserve.
`repo:` remains a supported field as a deliberate escape hatch (one-off forks, per-project overrides), not as a legacy shim.

To adopt the new model:
1. Populate the manifest (`gemkeeper manifest generate`, or `gemkeeper setup` from a `Gemfile.lock`).
2. Run `gemkeeper setup` — the generated `gemkeeper.yml` carries `name:` and `version:` only.
3. Verify with a test `gemkeeper sync`.

## Resolved Decisions

1. **`sync --manifest` flag** — not added. `sync` uses the default manifest path (`~/.config/gemkeeper/manifest.yml`). Overriding the manifest path is a `setup`/`generate` (configuration-time) concern, not a runtime one.
2. **Re-running `setup` strips `repo:`** — yes, and it falls out of the existing merge for free: `ConfigGenerator#merge` already does `entry.except("version", "repo", "name").merge(new_entry)`, so once `new_entry` stops carrying `repo:`, re-running `setup` promotes an entry to manifest-only.
3. **`manifest validate --resolve` before `sync`** — recommend it in the README as an optional pre-flight, not a required step.
4. **Portability** — acceptable by design. `gemkeeper.yml` is local-only; the manifest is the artifact you share to seed a machine. See Trade-offs.
