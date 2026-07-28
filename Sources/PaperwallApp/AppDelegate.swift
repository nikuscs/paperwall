import AppKit
import PaperwallPlayback
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wallpaperController = WallpaperController()
    private let discoveryLibrary = DiscoveryLibraryModel()
    private var windowController: PaperwallWindowController?
    private var statusItem: NSStatusItem?
    private var launchAtLoginItem: NSMenuItem?
    private var saverStatusItem: NSMenuItem?
    private var generationInProgress = false
    private let discoveryMenu = NSMenu(title: "Import from Discovery Cache")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        installStatusItem()
        do {
            try BundledComponentInstaller.installIfNeeded()
        } catch {
            presentError("Could not install Paperwall components: \(error.localizedDescription)")
        }
        installMainWindow()
        windowController?.show()
        discoveryLibrary.synchronize()
        Task {
            await resumePendingWorkIfNeeded()
        }
        Task {
            do {
                try await PaperwallUpscaleService.ensureToolInstalled()
            } catch {
                NSLog("Paperwall: 4K upscaler setup unavailable: %@", error.localizedDescription)
            }
        }
        Task {
            let active = PaperwallConfiguration.defaultAssetURL
            if FileManager.default.fileExists(atPath: active.path) {
                do {
                    try await NativeWallpaperExtensionBridge.deployActiveWallpaper(from: active)
                } catch {
                    NSLog("Paperwall: native Lock Screen deployment unavailable: %@", error.localizedDescription)
                }
            }
            await wallpaperController.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard generationInProgress else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Wallpaper processing is still running"
        alert.informativeText = "Quitting now interrupts local processing. The saved job remains resumable when Paperwall opens again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperController.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        windowController?.show()
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Paperwall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Bundle.main.url(forResource: "PaperwallLogo", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(
                systemSymbolName: "photo.circle",
                accessibilityDescription: "Paperwall"
            )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
        item.button?.toolTip = "Paperwall ®"
        item.isVisible = true

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Paperwall", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start", action: #selector(startPlayback), keyEquivalent: "")
        menu.addItem(withTitle: "Stop", action: #selector(stopPlayback), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select Video…", action: #selector(selectVideo), keyEquivalent: "")
        let discoveryItem = NSMenuItem(title: "Import from Discovery Cache", action: nil, keyEquivalent: "")
        discoveryItem.submenu = discoveryMenu
        menu.addItem(discoveryItem)
        menu.addItem(
            withTitle: "Generate Wallpaper…",
            action: #selector(generateWallpaper),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Open Asset Folder",
            action: #selector(openAssetFolder),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let launchItem = menu.addItem(
            withTitle: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem = launchItem
        menu.addItem(
            withTitle: "Configure Replicate Token…",
            action: #selector(configureReplicateToken),
            keyEquivalent: ""
        )
        let saverItem = NSMenuItem(title: "Native Lock Screen", action: nil, keyEquivalent: "")
        saverItem.isEnabled = false
        menu.addItem(saverItem)
        saverStatusItem = saverItem
        menu.addItem(
            withTitle: "Set Up Native Lock Screen…",
            action: #selector(openScreenSaverSettings),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Paperwall", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil { menuItem.target = self }
        item.menu = menu
        statusItem = item
        rebuildDiscoveryMenu()
    }

    private func installMainWindow() {
        windowController = PaperwallWindowController(
            discoveryLibrary: discoveryLibrary,
            generateImage: { [weak self] prompt, completion in
                self?.submitImageGeneration(prompt: prompt, completion: completion)
            },
            generate: { [weak self] request, completion in
                self?.submitGeneration(request, completion: completion)
            },
            upscaleVideo: { [weak self] url, completion in
                self?.upscaleAndInstall(videoURL: url, completion: completion)
            },
            chooseVideo: { [weak self] in self?.selectVideo() },
            selectDiscovery: { [weak self] url, completion in
                self?.selectAsset(url, completion: completion)
            },
            setPlaybackSpeed: { [weak self] speed in self?.setPlaybackSpeed(speed) },
            configureToken: { [weak self] in self?.configureReplicateToken() },
            openSettings: { [weak self] in self?.openScreenSaverSettings() },
            hasActiveWork: { [weak self] in self?.generationInProgress == true },
            activationChanged: { [weak self] in self?.restoreStatusItemVisibility() }
        )
    }

    @objc private func showMainWindow() {
        windowController?.show()
    }

    private func restoreStatusItemVisibility() {
        if statusItem == nil { installStatusItem() }
        statusItem?.isVisible = true
        statusItem?.button?.isHidden = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLoginItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions/PaperwallWallpaperExtension.appex")
        saverStatusItem?.title = FileManager.default.fileExists(atPath: extensionURL.path)
            ? "Native Lock Screen: Ready"
            : "Native Lock Screen: Unavailable"
        rebuildDiscoveryMenu()
    }

    private func rebuildDiscoveryMenu() {
        discoveryMenu.removeAllItems()
        let videos = AssetLibrary.discoveryVideos()
        if videos.isEmpty {
            let empty = NSMenuItem(title: "No Cached Videos", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            discoveryMenu.addItem(empty)
            return
        }
        for url in videos {
            let item = NSMenuItem(
                title: url.deletingPathExtension().lastPathComponent,
                action: #selector(selectDiscoveryVideo(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            discoveryMenu.addItem(item)
        }
    }

    @objc private func startPlayback() {
        Task { await wallpaperController.start() }
    }

    @objc private func stopPlayback() {
        wallpaperController.stop()
    }

    @objc private func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectAsset(url)
    }

    @objc private func selectDiscoveryVideo(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        selectAsset(url)
    }

    @objc private func generateWallpaper() {
        guard !generationInProgress else {
            presentError("A wallpaper generation is already running.")
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose a reference image for the animated wallpaper"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        let providerPopup = NSPopUpButton(frame: NSRect(x: 0, y: 54, width: 360, height: 26))
        for provider in GenerationProvider.availableCases {
            providerPopup.addItem(withTitle: provider.displayName)
        }
        let promptField = NSTextField(frame: NSRect(x: 0, y: 8, width: 360, height: 26))
        promptField.placeholderString = "Optional motion prompt"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 88))
        form.addSubview(providerPopup)
        form.addSubview(promptField)

        let options = NSAlert()
        options.messageText = "Generate Animated Wallpaper"
        options.informativeText = "Choose a provider and describe only the motion you want."
        options.accessoryView = form
        options.addButton(withTitle: "Preview Cost")
        options.addButton(withTitle: "Cancel")
        guard options.runModal() == .alertFirstButtonReturn else { return }

        let provider = GenerationProvider.availableCases[providerPopup.indexOfSelectedItem]
        let request = GenerationRequest(
            provider: provider,
            prompt: promptField.stringValue,
            imageURL: imageURL
        )
        submitGeneration(request)
    }

    private func submitImageGeneration(
        prompt: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !generationInProgress else {
            let error = GenerationError.generationAlreadyRunning
            presentError(error.localizedDescription)
            completion(.failure(error))
            return
        }

        let quote: ImageGenerationQuote
        do {
            quote = try PaperwallImageGenerationService.quote(prompt: prompt)
        } catch {
            presentError(error.localizedDescription)
            completion(.failure(error))
            return
        }

        let approval = NSAlert()
        approval.alertStyle = .warning
        approval.messageText = "Generate Still Image for \(quote.formattedCost)?"
        approval.informativeText = "Paperwall will submit exactly one paid \(quote.modelName) request. The video will not be generated until you approve the image separately."
        approval.addButton(withTitle: "Generate Image for \(quote.formattedCost)")
        approval.addButton(withTitle: "Cancel")
        guard approval.runModal() == .alertFirstButtonReturn else {
            completion(.failure(GenerationError.approvalDeclined))
            return
        }

        let token: String
        do {
            token = try ReplicateCredentialStore.resolvedToken()
        } catch GenerationError.missingToken {
            guard let entered = promptForReplicateToken() else {
                completion(.failure(GenerationError.missingToken))
                return
            }
            token = entered
        } catch {
            presentError(error.localizedDescription)
            completion(.failure(error))
            return
        }

        generationInProgress = true
        Task {
            defer { generationInProgress = false }
            do {
                let result = try await PaperwallImageGenerationService.generate(
                    prompt: prompt,
                    token: token
                )
                completion(.success(result.imageURL))
            } catch {
                presentError(error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func submitGeneration(
        _ request: GenerationRequest,
        completion: ((Result<GenerationResult, Error>) -> Void)? = nil
    ) {
        guard !generationInProgress else {
            let error = GenerationError.generationAlreadyRunning
            presentError(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        let quote: GenerationQuote
        do {
            quote = try PaperwallGenerationService.quote(for: request)
        } catch {
            presentError(error.localizedDescription)
            completion?(.failure(error))
            return
        }

        let approval = NSAlert()
        approval.alertStyle = .warning
        approval.messageText = "Approve \(quote.formattedCost) Maximum Spend?"
        approval.informativeText = "Paperwall will submit exactly one paid \(request.provider.displayName) request. Failed or canceled generations are never retried automatically."
        approval.addButton(withTitle: "Generate for \(quote.formattedCost)")
        approval.addButton(withTitle: "Cancel")
        guard approval.runModal() == .alertFirstButtonReturn else {
            completion?(.failure(GenerationError.approvalDeclined))
            return
        }

        let token: String
        do {
            token = try ReplicateCredentialStore.resolvedToken()
        } catch GenerationError.missingToken {
            guard let entered = promptForReplicateToken() else {
                completion?(.failure(GenerationError.missingToken))
                return
            }
            token = entered
        } catch {
            presentError(error.localizedDescription)
            completion?(.failure(error))
            return
        }

        generationInProgress = true
        Task {
            defer { generationInProgress = false }
            do {
                let result = try await PaperwallGenerationService.generateAndSelect(
                    request: request,
                    token: token,
                    approve: { _ in true }
                )
                wallpaperController.stop()
                await wallpaperController.start()
                if let completion {
                    completion(.success(result))
                } else {
                    let complete = NSAlert()
                    complete.messageText = "Wallpaper Generated"
                    complete.informativeText = "Installed \(result.provider.displayName) output \(result.predictionID)."
                    complete.runModal()
                }
            } catch {
                presentError(error.localizedDescription)
                completion?(.failure(error))
            }
        }
    }

    private func upscaleAndInstall(
        videoURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !generationInProgress else {
            completion(.failure(GenerationError.generationAlreadyRunning))
            return
        }
        generationInProgress = true
        Task {
            defer { generationInProgress = false }
            do {
                let result = try await PaperwallUpscaleService.upscaleTo4K(videoURL: videoURL)
                _ = try await PaperwallService.selectWallpaper(from: result.upscaledVideoURL)
                wallpaperController.stop()
                await wallpaperController.start()
                completion(.success(result.upscaledVideoURL))
            } catch {
                presentError(error.localizedDescription)
                completion(.failure(error))
            }
        }
    }

    private func resumePendingWorkIfNeeded() async {
        guard !generationInProgress,
              let token = try? ReplicateCredentialStore.resolvedToken()
        else { return }

        generationInProgress = true
        defer { generationInProgress = false }
        do {
            if let prompt = PaperwallImageGenerationService.pendingPrompt() {
                _ = try await PaperwallImageGenerationService.generate(prompt: prompt, token: token)
            }
            if let request = PaperwallGenerationService.pendingRequest() {
                let generated = try await PaperwallGenerationService.generateAndSelect(
                    request: request,
                    token: token,
                    approve: { _ in false }
                )
                let upscaled = try await PaperwallUpscaleService.upscaleTo4K(
                    videoURL: generated.generatedVideoURL
                )
                _ = try await PaperwallService.selectWallpaper(from: upscaled.upscaledVideoURL)
                wallpaperController.stop()
                await wallpaperController.start()
            }
        } catch {
            NSLog("Paperwall: pending work remains resumable: %@", error.localizedDescription)
        }
    }

    private func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        do {
            try PlaybackPreferences.save(playbackSpeed: speed)
            wallpaperController.setPlaybackSpeed(speed)
        } catch {
            presentError("Could not save playback speed: \(error.localizedDescription)")
        }
    }

    @objc private func configureReplicateToken() {
        _ = promptForReplicateToken()
    }

    private func promptForReplicateToken() -> String? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "r8_…"
        let alert = NSAlert()
        alert.messageText = "Replicate API Token"
        alert.informativeText = "The token is stored in your macOS Keychain and is never written to Paperwall metadata."
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save in Keychain")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            presentError("Enter a Replicate API token.")
            return nil
        }
        do {
            try ReplicateCredentialStore.saveToken(token)
            return token
        } catch {
            presentError(error.localizedDescription)
            return nil
        }
    }

    private func selectAsset(
        _ url: URL,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        Task {
            wallpaperController.stop()
            do {
                _ = try await PaperwallService.selectWallpaper(from: url)
                await wallpaperController.start()
                completion?(.success(()))
            } catch {
                await wallpaperController.start()
                presentError("Could not select the wallpaper: \(error.localizedDescription)")
                completion?(.failure(error))
            }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if LaunchAtLoginManager.isEnabled {
                try LaunchAtLoginManager.disable()
            } else {
                try LaunchAtLoginManager.enable(appURL: Bundle.main.bundleURL)
            }
            launchAtLoginItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
        } catch {
            presentError(error.localizedDescription)
        }
    }

    @objc private func openScreenSaverSettings() {
        let guide = NSAlert()
        guide.messageText = "Enable Paperwall on the Native Lock Screen"
        guide.informativeText = "1. Find Paperwall — Animated Wallpapers.\n2. Select Paperwall.\n3. Enable Show as Screen Saver if macOS displays the option.\n\nAfter this one-time selection, wallpapers applied in Paperwall update the Desktop and Lock Screen together."
        guide.addButton(withTitle: "Open Wallpaper Settings")
        guide.addButton(withTitle: "Cancel")
        guard guide.runModal() == .alertFirstButtonReturn else { return }

        let links = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
        ]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func openAssetFolder() {
        let directory = PaperwallConfiguration.applicationSupportDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            presentError("Could not open the asset folder: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Paperwall"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
