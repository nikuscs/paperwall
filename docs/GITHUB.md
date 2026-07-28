# GitHub security and releases

## Repository state

- Repository: `nikuscs/paperwall`
- Visibility: private until the publication gate is approved
- Default branch: `main`
- Default workflow token: read-only; workflows cannot create or approve pull requests
- Allowed Actions: GitHub-owned only
- Full-SHA Action pinning: required
- Dependabot vulnerability alerts and automated security fixes: enabled
- Wiki and Projects: disabled
- Workflow caches: none
- Release environment: `release`, restricted to `main` and `v*`
- Release environment secrets: none configured
- Required release reviewer: blocked by the private-repository plan; set sole reviewer `nikuscs` immediately after publication

## Release trust boundary

Cloud release is intentionally dormant while the repository is private. `.github/workflows/release.yml` fails its guard before building unless the repository is public and the event is a `v*` tag.

The release flow uses three fresh hosted runners:

1. **Build** — checks out the exact tag, downloads only checksum-pinned `uv`, XcodeGen, and Gitleaks inputs, builds without secrets or OIDC, records the unsigned ZIP digest, and uploads a one-day artifact.
2. **Sign** — waits on the `release` environment, verifies the unsigned digest, imports the Developer ID certificate into an ephemeral keychain, signs and notarizes without package installs or caches, deletes key material, records the DMG digest, and uploads a seven-day artifact.
3. **Publish** — waits on `release`, verifies the signed digest, creates GitHub provenance attestation on a fresh runner without signing secrets, and publishes the existing tag and DMG through `gh`.

No release job runs on pull requests, uses `pull_request_target`/`workflow_run`, consumes PR artifacts, restores caches, or executes package-manager installs while signing/publishing credentials are present.

## Release environment secrets

Configure these only after the repository is public and reviewer protection is verified. Keep them environment-scoped; never duplicate them as repository secrets.

- `APPLE_CERTIFICATE_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_TEAM_ID`
- `APPLE_NOTARY_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Use a dedicated Developer ID certificate and App Store Connect API key that can be revoked independently. Never print or bundle their values.

## Public transition gate

Immediately after changing visibility to public:

1. Set fork workflow approval to `all_external_contributors`.
2. Add `nikuscs` as the sole required reviewer for `release` (`prevent_self_review` remains off because there is no second reviewer).
3. Verify `release` permits only `main` and `v*`.
4. Enable secret scanning, push protection, private vulnerability reporting, and code scanning.
5. Protect `main` from force-push and deletion. Apply CODEOWNER review only when another qualified reviewer exists; a sole owner cannot independently approve their own PR.
6. Enable immutable releases when available.
7. Re-run `~/.agents/skills/secure-github-repo/scripts/audit.py` and strict pedantic Zizmor at the publication SHA.
8. Configure release secrets only after every preceding control is verified.

Until this gate is complete, sign locally with a Keychain profile and publish no cloud-signed release.

## Tool pin policy

`Config/release-tools.env` is the source of truth for release-tool versions and archive SHA-256 values. `Scripts/bootstrap_release_tools.sh` downloads immutable release assets over HTTPS and verifies them before execution or embedding. Updating a tool requires:

1. verify the release in the upstream repository
2. record the GitHub release asset digest for both supported macOS architectures
3. run the bootstrap, tests, unsigned release build, and strict Zizmor
4. review the generated Xcode project diff

Do not replace this with mutable Homebrew installs in release or CI jobs.
