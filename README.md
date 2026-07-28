# Paperwall

Native macOS animated wallpapers for the desktop and Lock Screen, with optional AI generation through Replicate.

> [!WARNING]
> Paperwall targets macOS 27 and uses private, unsupported WallpaperExtensionKit APIs. Compatibility may break after macOS updates, and Paperwall is not eligible for Mac App Store distribution.

## Install

Download `Paperwall.dmg` from the repository's Releases page.

1. Open `Paperwall.dmg`.
2. Drag **Paperwall** to **Applications**.
3. Launch Paperwall.

On first launch, the app installs its CLI and deploys the active video to its embedded native wallpaper extension. Select **Paperwall** once under System Settings → Wallpaper and enable **Show as Screen Saver** when offered. After that one-time setup, applying a wallpaper in Paperwall updates the native Desktop and animated Lock Screen together. A legacy `Paperwall.saver` is also installed as a fallback.

The native integration uses macOS's private `WallpaperExtensionKit` runtime, following Phosphene's MIT-licensed approach. It is validated on macOS 27 but may require compatibility updates after major macOS releases.

If your shell does not include `~/.local/bin`, add it to `PATH`.

## Storage and multi-Mac sync

Paperwall stores sync-safe wallpapers, imported library videos, generated images and videos, source images, 4K upscales, and one editable `.paperwall.json` metadata sidecar per asset under `~/.config/paperwall`. Sidecars carry titles, descriptions, tags, provenance, dimensions, duration, and stable content IDs. Each Mac builds a fast local SQLite catalog at `~/Library/Application Support/Paperwall/Catalog/catalog.sqlite3`; the database is disposable and never synchronized. Machine-specific playback state, the active `current.mov`, native fallbacks, generation jobs, locks, and logs also remain under Application Support. Existing media is copied non-destructively into the shared location on first launch.

## Generate

In the app, describe a scene and generate a still image first. Review it, then choose **Animate** to submit a separately approved video request. Paperwall automatically upscales the finished video to 4K using the free `venhance` Real-ESRGAN pipeline. The app bundles its setup bootstrap, verifies the pinned upscaler at every launch, and installs it automatically when missing. Image and video spending are confirmed independently; interrupted predictions resume safely and failed upscaling can be retried.

Set `REPLICATE_API_TOKEN` in your shell, or choose **Configure Replicate Token…** in the menu-bar app.

```bash
paperwall generate --provider seedance-1.5 --image image.png --prompt "leaves sway"
paperwall generate --provider seedance-2.0 --prompt "slow clouds over a lake"
```

Use `--dry-run` to preview cost without spending. Paid submissions always require exact confirmation and are never retried automatically.

## Commands

```bash
paperwall set video.mp4
paperwall discovery-list
paperwall discovery-set ID
paperwall start
paperwall stop
paperwall status
paperwall enable
paperwall disable
paperwall saver settings
paperwall asset
```

Run `paperwall help` for the full concise syntax.

## Developer setup

Development requires macOS 27 and Xcode 27. Distribution and CI download pinned XcodeGen, `uv`, and Gitleaks archives and verify their committed SHA-256 digests before use.

## Developer commands

```bash
make install       # build and install Paperwall.app in /Applications
make install-cli   # install only ~/.local/bin/paperwall
make uninstall-cli # remove only the CLI
make install-app   # build DMG and install to ~/Applications (local testing)
make uninstall-app
make test
make dmg
```

`make dmg` creates `dist/Paperwall.dmg`. Without signing credentials it is an ad-hoc development build. Public distribution requires a Developer ID Application certificate and a `notarytool` Keychain profile:

```bash
xcrun notarytool store-credentials paperwall-notary \
  --apple-id "APPLE_ID" \
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"

PAPERWALL_SIGN_IDENTITY="Developer ID Application: Name (TEAM_ID)" \
PAPERWALL_NOTARY_PROFILE="paperwall-notary" \
make dmg
```

The local build signs the app, nested executables, extension, screen saver, and DMG with hardened runtime and secure timestamps. When a notary profile is supplied, it submits the DMG, waits for acceptance, staples the ticket, and validates the staple.

The guarded GitHub release workflow activates only for `v*` tags after the repository becomes public. It builds without credentials, signs/notarizes on a fresh cache-free runner behind the `release` environment, then attests and publishes from another runner without signing secrets. See [`docs/GITHUB.md`](docs/GITHUB.md).

## Security and privacy

See [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md). Never report live API tokens or private media in public issues.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Paperwall is source-available under a non-commercial, attribution, share-alike license matching Browser Clutch. See [LICENSE.md](LICENSE.md). Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
