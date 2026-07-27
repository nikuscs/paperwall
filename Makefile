SHELL := /bin/bash
DERIVED_DATA := build/DerivedData
CLI_PRODUCT := $(DERIVED_DATA)/Build/Products/Release/paperwall
CLI_DESTINATION := $(HOME)/.local/bin/paperwall

.PHONY: install install-cli uninstall-cli install-app uninstall-app dmg test

install: dmg
	./Scripts/install_dmg.sh dist/Paperwall.dmg /Applications/Paperwall.app

install-cli:
	xcodegen generate
	xcodebuild build -project Paperwall.xcodeproj -scheme PaperwallCLI -configuration Release -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO
	mkdir -p "$(dir $(CLI_DESTINATION))"
	install -m 755 "$(CLI_PRODUCT)" "$(CLI_DESTINATION).stage"
	codesign --force --sign - "$(CLI_DESTINATION).stage"
	mv -f "$(CLI_DESTINATION).stage" "$(CLI_DESTINATION)"
	@echo "Installed $(CLI_DESTINATION)"

uninstall-cli:
	rm -f "$(CLI_DESTINATION)"

install-app: dmg
	./Scripts/install_dmg.sh dist/Paperwall.dmg

uninstall-app:
	./Scripts/uninstall_local.sh

dmg:
	./Scripts/build_dmg.sh

test:
	xcodegen generate
	xcodebuild test -project Paperwall.xcodeproj -scheme PaperwallPlayback -destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA)
