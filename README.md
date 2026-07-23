# saw-agent releases

Signed release artifacts for the SAW remote agent.

- Channels: `dev` (prereleases, tag `dev-v*`) and `stable` (tag `v*`).
- Each release carries `manifest.json` + `manifest.json.minisig` (minisign-signed: version, channel, commit, min_version, artifact sha256s).
- **Yank** = re-publish the manifest with `yanked: true`. **Never delete releases** — a deleted head would downgrade the fleet.
- Publishing is CI-only (saw-agent release lanes). Token custody: see saw-docs plan/saw-agent-auto-update-plan.md §2.7.
