# Security Policy

## Supported versions

Security fixes are provided for the latest release on `main`. Paperwall currently targets macOS 27 and uses private WallpaperExtensionKit behavior that may change between macOS releases.

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities involving credentials, arbitrary file access, process execution, installers, XPC validation, or paid API requests. Use GitHub's **Security → Report a vulnerability** flow for this repository. Include reproduction steps, affected macOS version, and impact. Do not include live API tokens or private media.

## Credential and generation guarantees

- Replicate credentials are read from `REPLICATE_API_TOKEN` or macOS Keychain and are never written to job metadata.
- Authorization headers are sent only to `https://api.replicate.com`.
- Child video-processing tools receive an environment with credential-like variables removed.
- Paid image and video submissions require separate explicit approval.
- Paid POST requests are never automatically retried.
- Interrupted jobs resume from persisted prediction IDs without creating another paid submission.

## Release security guarantees

- CI and release tools are downloaded at committed versions and verified against committed SHA-256 digests before execution or embedding.
- Pull-request workflows receive no signing or notarization credentials and cannot invoke the release environment.
- Cloud releases remain disabled while the repository is private.
- Unsigned builds run without secrets or OIDC; signing/notarization and publication run on separate fresh, cache-free runners behind the `release` environment.
- Signing and notarization credentials are environment-scoped and are never repository secrets.
- Signed artifacts are digest-verified before provenance attestation and publication.

## Private API notice

The native animated Lock Screen integration uses undocumented macOS APIs. This is a compatibility and stability risk, not a claim of Apple endorsement. Paperwall is not suitable for Mac App Store distribution.
