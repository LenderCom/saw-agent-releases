# saw-agent releases

Signed release artifacts for the SAW remote agent.

- Channels: `dev` (prereleases, tag `dev-v*`) and `stable` (tag `v*`).
- Each release carries `manifest.json` + `manifest.json.minisig` (minisign-signed: version, channel, commit, min_version, artifact sha256s).
- **Yank** = re-publish the manifest with `yanked: true`. **Never delete releases** — a deleted head would downgrade the fleet.
- Publishing is CI-only (saw-agent release lanes). Token custody: see saw-docs plan/saw-agent-auto-update-plan.md §2.7.
- `scripts/staleness-check.sh` is the fleet-staleness alarm (see `.github/workflows/staleness-cron.yml`). It talks to the fleet endpoint's real Envelope response shape (`{ok, data: {channels, machines}}`) and, if the check itself fails (bad HTTP status, malformed body), posts a distinct "staleness-check itself failed" Discord notice before exiting non-zero — the alarm mechanism failing is never silent. `./scripts/staleness-check.self-test.sh` drives it against a local mock of GitHub/fleet/Discord with real envelope-shaped fixtures and asserts the healthy/alarm/failure-notice outcomes; run it after touching the script.
