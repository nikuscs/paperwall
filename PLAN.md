# Paperwall

## Product

A user-scoped macOS animated-wallpaper system with:

- Desktop playback through `Paperwall.app`.
- Lock Screen playback through `Paperwall.saver`.
- A compiled `paperwall` CLI and menu-bar UI.
- AI generation through Replicate.
- Launch-at-login persistence and reversible uninstall.

## Architecture

- `PaperwallPlayback`: shared core for generation, validation, import, playback, static fallback, credentials, and persistence.
- `PaperwallApp`: menu-bar UI and desktop windows.
- `PaperwallCLI`: thin command interface over the core.
- `PaperwallScreenSaver`: thin screen-saver host over shared playback.

The active video is always copied to:

```text
~/Library/Application Support/Paperwall/current.mov
```

The core generates `fallback.jpg` from its first frame and applies it as the native wallpaper. Uninstall restores the previous native wallpaper.

## AI generation safety

Provider aliases:

- `seedance-1.5` → `bytedance/seedance-1.5-pro`
- `seedance-2.0` → `bytedance/seedance-2.0`

Before any paid POST, Paperwall shows the maximum estimated cost and requires explicit confirmation. Paid submissions are never retried. Submission intent and prediction IDs are persisted; only status/download requests receive bounded retries, and interrupted jobs resume the same prediction.

`REPLICATE_API_TOKEN` is read from the environment first and macOS Keychain second. It is never printed or stored in generation metadata.

## Acceptance

- CLI and UI use the same core generation/import APIs.
- Generated output is validated before activation.
- Desktop, saver, static fallback, and login persistence use Paperwall-owned files only.
- Source images, imported sources, Wallspace cache files, and generated history are preserved non-destructively.
- Install and uninstall remain user-scoped and transactional.
