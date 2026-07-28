# Privacy

Paperwall does not include analytics, advertising, crash-reporting SDKs, or a Paperwall-operated cloud service.

## Local data

Wallpaper media, metadata, generated outputs, job state, and the local catalog are stored on the Mac in the locations documented in [README.md](README.md). Multi-Mac synchronization is user-managed; Paperwall does not operate the synchronization service.

## Replicate

AI generation is optional. When a user explicitly approves a paid generation, Paperwall sends the entered prompt and any selected reference image to Replicate. Replicate processes and stores those requests under the user's own account and policies. The API token is read from the environment or macOS Keychain and is sent only to `https://api.replicate.com`.

## Upscaling dependencies

The optional 4K pipeline installs pinned `venhance` source through bundled `uv`. This contacts GitHub and Python package infrastructure and may download model weights from upstream project releases. Child processing tools do not receive credential-like environment variables.

## macOS services

Paperwall uses macOS wallpaper, screen saver, Keychain, login-item, and file APIs. Its native animated Lock Screen integration uses private WallpaperExtensionKit behavior. Apple may collect diagnostics according to the Mac's system privacy settings.
