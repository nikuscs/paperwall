# Paperwall

Native macOS animated wallpapers for the desktop and Lock Screen, with AI generation through Replicate.

## Install

1. Open `Paperwall.dmg`.
2. Drag **Paperwall** to **Applications**.
3. Launch Paperwall.

On first launch, the app automatically installs its bundled CLI to `~/.local/bin/paperwall` and screen saver to `~/Library/Screen Savers/Paperwall.saver`. Select **Paperwall** once in System Settings → Screen Saver for Lock Screen playback.

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

`make dmg` creates `dist/Paperwall.dmg`. Without signing credentials it is an ad-hoc development build. Public distribution requires:

```bash
PAPERWALL_SIGN_IDENTITY="Developer ID Application: …" \
PAPERWALL_NOTARY_PROFILE="notary-profile" \
make dmg
```
