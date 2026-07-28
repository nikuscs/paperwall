# Contributing

Thanks for your interest in Paperwall.

## Requirements

- macOS 27
- Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [`uv`](https://github.com/astral-sh/uv) for distribution builds

## Development

```bash
git clone https://github.com/nikuscs/paperwall.git
cd paperwall
xcodegen generate
make test
make dmg
```

`make dmg` creates an ad-hoc development build unless Developer ID and notarization credentials are supplied. Never commit signing certificates, provisioning profiles, API keys, Keychain exports, generated media, or DMG files.

## Pull requests

1. Branch from `main`.
2. Keep the change focused.
3. Run `make test`.
4. Explain user-visible behavior and private-API compatibility implications.
5. Do not weaken paid-request safeguards: paid submissions require explicit approval and are never automatically retried.

Changes to `.github/`, signing, notarization, credential handling, the WallpaperExtensionKit bridge, installers, or update behavior require maintainer review.

## License

By contributing, you agree that your contribution is licensed under [Paperwall's non-commercial share-alike license](LICENSE.md).
