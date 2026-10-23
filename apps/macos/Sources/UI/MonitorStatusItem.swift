import AppKit
import Combine
import SwiftUI

/// A second menu-bar item with the chosen readings as text. Click it for everything the Mac reports.
final class MonitorStatusItem: NSObject, NSPopoverDelegate {
    private let monitor: SystemMonitor
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var viewing = false

    init(monitor: SystemMonitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        monitor.$showInMenuBar.receive(on: DispatchQueue.main).sink { [weak self] on in self?.setVisible(on) }.store(in: &cancellables)
        monitor.$snapshot.combineLatest(monitor.$metrics).receive(on: DispatchQueue.main).sink { [weak self] snap, metrics in self?.refresh(snap, metrics) }.store(in: &cancellables)
    }

    private func setVisible(_ on: Bool) {
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            self.item = item
            refresh(monitor.snapshot, monitor.metrics)
        } else if !on, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    private func refresh(_ snapshot: MonitorSnapshot, _ metrics: [MonitorMetric]) {
        guard let button = item?.button else { return }
        let text = snapshot.menuBarText(metrics)
        if button.title != text { button.title = text }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        let host = NSHostingController(rootView: LiveDetails(monitor: monitor))
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 360, height: 560)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        if !viewing { viewing = true; monitor.viewerAppeared() }
    }

    func popoverDidClose(_ notification: Notification) {
        if viewing { viewing = false; monitor.viewerGone() }
    }
}

private struct LiveDetails: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        ScrollView { Form { SystemDetails(snapshot: monitor.snapshot, info: monitor.info) }.formStyle(.grouped).scrollDisabled(true) }
            .frame(width: 360, height: 560)
    }
}
