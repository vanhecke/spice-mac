// SPDX-License-Identifier: MIT
import AppKit
import Combine
import CocoaSpice
import SpiceController
import DisplayScale

/// Owns one SPICE session window: hosts the `SpiceDisplayView`, reflects
/// connection state, resizes to the guest, and exposes the Connection/USB menu
/// actions via the responder chain.
final class SpiceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private let client: SpiceClient
    private let sourceURL: URL
    private let displayView = SpiceDisplayView()
    private let containerView = NSView()
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private var cancellables = Set<AnyCancellable>()

    /// Called when the window closes so the app can drop its reference.
    var onClose: (() -> Void)?

    /// The last guest size we asked for. Suppresses a redundant monitor-config,
    /// which costs a real mode switch; cleared when the display/agent state
    /// restarts.
    private var lastRequestedGuestSize: CGSize?

    /// Coalesces resolution requests: one drag across a screen boundary fires
    /// several.
    private var pendingResolutionRequest: DispatchWorkItem?

    /// Block-based NotificationCenter observers, removed on close.
    private var notificationObservers: [NSObjectProtocol] = []

    init(client: SpiceClient, sourceURL: URL) {
        self.client = client
        self.sourceURL = sourceURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.title = baseTitle
        window.center()
        setupViews()
        wireClient()
        wireNotifications()
    }

    deinit {
        pendingResolutionRequest?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var baseTitle: String {
        client.title ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Views

    private func setupViews() {
        guard let window else { return }
        containerView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        displayView.autoresizingMask = [.width, .height]
        displayView.frame = containerView.bounds
        containerView.addSubview(displayView)
        // The view is the only place that learns about a backing-scale change
        // (NSView.viewDidChangeBackingProperties). It reports it up so we can
        // re-request a guest resolution: at a fixed zoom, moving between a Retina and
        // a 1x screen changes drawable/zoom and so the resolution the guest should be
        // at. In Automatic it does not, and the idempotence guard turns this into a
        // no-op — which is exactly the point of Automatic.
        displayView.onBackingScaleChange = { [weak self] _ in
            self?.scheduleResolutionRequest()
        }

        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = containerView
        window.initialFirstResponder = displayView
    }

    // MARK: - Client wiring

    private func wireClient() {
        client.onDisplayCreated = { [weak self] display in self?.attachDisplay(display) }
        // NB: do NOT resize the window when the guest resolution changes. The view
        // re-fits the viewport via its displaySize KVO, so the window stays the
        // user's size. Resizing here would chase the guest size and, combined with
        // requestResolution, oscillate (the guest reconfigures → window resizes →
        // we request a new resolution → …).
        client.onDisplayDestroyed = { [weak self] _ in self?.displayView.detach() }
        client.onInputAvailable = { [weak self] input in
            guard let self else { return }
            self.displayView.router.input = input
            self.displayView.router.requestMouseMode(server: false)
            self.window?.makeFirstResponder(self.displayView)
        }
        client.onInputUnavailable = { [weak self] _ in self?.displayView.router.input = nil }

        client.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update(for: $0) }
            .store(in: &cancellables)

        client.$agentConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                // A fresh agent means a fresh guest display stack, so forget what we
                // asked the previous one for.
                self.lastRequestedGuestSize = nil
                if connected { self.scheduleResolutionRequest(after: 0.15) }
            }
            .store(in: &cancellables)
    }

    private func wireNotifications() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .displayZoomChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyZoomChange()
        })
        // Hotplug/removal, sleep/wake, and Displays "scaled resolution" changes,
        // which resize the window WITHOUT a live resize. Longer delay: AppKit keeps
        // shuffling windows for a while after these.
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.scheduleResolutionRequest(after: 0.6)
        })
    }

    private func attachDisplay(_ display: CSDisplay) {
        displayView.attachDisplay(display)
        lastRequestedGuestSize = nil   // a re-attach means a fresh guest surface
        resizeToDisplay(display.displaySize, recenter: true)
        // The agent-connected and display-created edges race, and whichever loses
        // has to be the one that asks. Safe against the oscillation rule:
        // spiceDisplayCreated is a one-shot per display channel (later configs fire
        // spiceDisplayUpdated).
        scheduleResolutionRequest(after: 0.15)
        statusLabel.isHidden = true
        window?.makeFirstResponder(displayView)
        if client.prefersFullscreen, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    private func update(for status: SpiceClient.Status) {
        switch status {
        case .idle:
            statusLabel.stringValue = ""
        case .connecting:
            showStatus("Connecting…")
        case .connected:
            statusLabel.isHidden = true
            client.usbManager?.delegate = self
            refreshUSBMenu()
        case .disconnected:
            // The SPICE ticket is single-use, so reconnecting needs a fresh file.
            showStatus("Disconnected.\nOpen a fresh .vv file to reconnect.")
        case .failed(let message):
            showStatus("Connection failed.\n\(message)")
        }
        window?.title = title(for: status)
    }

    private func title(for status: SpiceClient.Status) -> String {
        switch status {
        case .connecting:   return "\(baseTitle) — Connecting…"
        case .disconnected: return "\(baseTitle) — Disconnected"
        case .failed:       return "\(baseTitle) — Failed"
        case .connected, .idle: return baseTitle
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Sizing

    /// Backing scale of the screen this window is currently on.
    private var currentBackingScale: CGFloat {
        window?.backingScaleFactor ?? displayView.backingScale
    }

    /// Size the window so `size` guest pixels occupy `guest × zoom / backingScale`
    /// points, clamped to what the screen can show. `recenter` only on attach; a
    /// later zoom change keeps the window's top-left where the user put it.
    private func resizeToDisplay(_ size: CGSize, recenter: Bool) {
        guard size.width > 1, size.height > 1, let window,
              window.styleMask.contains(.fullScreen) == false else { return }
        // Clamp against the CONTENT rect the visible frame allows, not the frame
        // itself — the title bar takes ~28 pt off the top.
        let allowed = (window.screen ?? NSScreen.main)
            .map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        let target = DisplayScale.windowContentPoints(guest: size,
                                                      zoom: Preferences.displayZoom,
                                                      backingScale: window.backingScaleFactor,
                                                      maximum: allowed)
        if recenter {
            window.setContentSize(target)
            window.center()
        } else {
            // setContentSize keeps the frame's bottom-left; users expect the
            // top-left to stay put. Constrain afterwards so the title bar stays
            // reachable.
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(target)
            window.setFrameTopLeftPoint(topLeft)
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen),
                            display: true)
        }
    }

    /// Ask the guest for `windowPoints × backingScale / zoom` — exactly `zoom` host
    /// pixels per guest pixel once it reconfigures. `SpiceDisplayView`'s aspect-fit
    /// then derives the same factor, so the renderer and the input router follow
    /// for free.
    private func requestResolutionForCurrentSize() {
        guard client.supportsDynamicResolution,
              let display = displayView.attachedDisplay else { return }
        let target = DisplayScale.targetGuestSize(viewPoints: displayView.bounds.size,
                                                  backingScale: currentBackingScale,
                                                  zoom: Preferences.displayZoom)
        guard DisplayScale.needsRequest(target: target,
                                        current: display.displaySize,
                                        lastRequested: lastRequestedGuestSize) else { return }
        lastRequestedGuestSize = target
        display.requestResolution(CGRect(origin: .zero, size: target))
    }

    /// Coalesced entry point for a resolution request.
    ///
    /// NB: every caller is a HOST-side geometry event or the one-shot agent edge.
    /// Nothing guest-side may call it — a guest resolution change must only re-fit
    /// the viewport, or the resize↔request oscillation this app already fixed comes
    /// back.
    private func scheduleResolutionRequest(after delay: TimeInterval = 0.3) {
        pendingResolutionRequest?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResolutionRequest = nil
            // Never fire mid-drag; windowDidEndLiveResize will reschedule us.
            guard self.window?.inLiveResize != true else { return }
            self.requestResolutionForCurrentSize()
        }
        pendingResolutionRequest = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The user picked a new zoom.
    ///
    /// With a guest agent the window is the user's chosen viewport and must NOT
    /// change: only the guest's pixel density does, so we re-request. Without one
    /// the guest resolution is fixed, so the only way to honour the zoom is the
    /// other side of the equation — resize the window to `guest × zoom /
    /// backingScale` points. That cannot reopen the oscillation: a programmatic
    /// setContentSize is not a live resize.
    private func applyZoomChange() {
        if client.supportsDynamicResolution {
            scheduleResolutionRequest(after: 0.05)   // discrete user action: near-immediate
        } else if let size = displayView.attachedDisplay?.displaySize {
            resizeToDisplay(size, recenter: false)
        }
        // Disconnected: nothing to do. The preference is global and persisted, so it
        // applies to the next session.
    }

    // Request a matching guest resolution only at DISCRETE moments — never on the
    // continuous windowDidResize, which (during a live drag, or when a programmatic
    // resize fires it) creates the resize↔request oscillation.
    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    // MARK: - Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(displayView)
        client.usbManager?.delegate = self
        refreshUSBMenu()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Release any held input so it does not stay latched in the guest when the
        // user switches away, and restore the macOS cursor — the window is no longer
        // key, so updateHostCursorVisibility() shows it (covers same-app window
        // switches / miniaturize that don't deactivate the app).
        displayView.router.releaseAll()
        displayView.updateHostCursorVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        pendingResolutionRequest?.cancel()
        pendingResolutionRequest = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
        displayView.router.releaseAll()
        client.disconnect()
        displayView.detach()
        onClose?()
    }

    // MARK: - Connection actions (responder chain targets)

    @objc func sendCtrlAltDel(_ sender: Any?) {
        guard let input = displayView.router.input else { return }
        // Left Ctrl (0x1D) + Left Alt (0x38) + Delete (extended 0xE053 → 0x153).
        let combo: [Int32] = [0x1D, 0x38, 0x153]
        for code in combo { input.send(.press, code: code) }
        for code in combo.reversed() { input.send(.release, code: code) }
    }

    @objc func releaseCursor(_ sender: Any?) {
        displayView.router.releaseAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sendCtrlAltDel(_:)), #selector(releaseCursor(_:)):
            return displayView.router.input != nil
        default:
            return true
        }
    }

    // MARK: - USB menu

    @objc func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CSUSBDevice,
              let usb = client.usbManager else { return }
        if usb.isUsbDeviceConnected(device) {
            usb.disconnectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        } else {
            var message: NSString?
            guard usb.canRedirectUsbDevice(device, errorMessage: &message) else {
                presentTransientError((message as String?) ?? "This USB device cannot be redirected.")
                return
            }
            usb.connectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        }
    }

    private func handleUSBResult(_ error: Error?) {
        DispatchQueue.main.async {
            if let error { self.presentTransientError(error.localizedDescription) }
            self.refreshUSBMenu()
        }
    }

    private func refreshUSBMenu() {
        // The USB submenu is shared app-wide; only the key window owns it, so
        // background windows' USB delegate callbacks don't retarget its items.
        guard window?.isKeyWindow == true, let menu = MainMenu.usbSubmenu else { return }
        menu.removeAllItems()
        guard let usb = client.usbManager else {
            menu.addItem(disabledItem("Not connected"))
            return
        }
        let devices = usb.usbDevices
        if devices.isEmpty {
            menu.addItem(disabledItem("No USB devices"))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: label(for: device),
                                  action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = usb.isUsbDeviceConnected(device) ? .on : .off
            menu.addItem(item)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func label(for device: CSUSBDevice) -> String {
        let name = device.name ?? device.usbProductName ?? "USB Device"
        return String(format: "%@ (%04lx:%04lx)", name, device.usbVendorId, device.usbProductId)
    }

    private func presentTransientError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "USB Redirection"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - CSUSBManagerDelegate

extension SpiceWindowController: CSUSBManagerDelegate {
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        DispatchQueue.main.async { self.presentTransientError(error) }
    }
}
