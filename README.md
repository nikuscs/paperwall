# Paperwall

Native macOS animated wallpapers for the desktop and Lock Screen, with AI generation through Replicate.

## Install

1. Open `Paperwall.dmg`.
2. Drag **Paperwall** to **Applications**.
3. Launch Paperwall.

On first launch, the app automatically installs its bundled CLI to `~/.local/bin/paperwall` and screen saver to `~/Library/Screen Savers/Paperwall.saver`. Select **Paperwall** once in System Settings → Screen Saver for Lock Screen playback.

If your shell does not include `~/.local/bin`, add it to `PATH`.

## Generate

In the app, describe a scene and generate a still image first. Review it, then choose **Animate** to submit a separately approved video request. Image and video spending are confirmed independently.

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
