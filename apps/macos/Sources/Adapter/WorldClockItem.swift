import AppKit
import Combine
import SwiftUI

/// Extra time zones in the menu bar, and a calendar glance when clicked.
final class WorldClockModel: ObservableObject {
    static let barKey = "worldClock.menuBar"
    private static let placesKey = "worldClock.places.v1"
    private static let hourKey = "worldClock.24h"

    @Published var places: [ClockPlace] { didSet { save() } }
    @Published var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Self.barKey) } }
    @Published var twentyFourHour: Bool { didSet { defaults.set(twentyFourHour, forKey: Self.hourKey) } }
    @Published private(set) var now = Date()
    @Published private(set) var events: [NextMeeting] = []

    private let defaults: UserDefaults
    private var timer: Timer?
    var meetings: MeetingSource?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        places = (defaults.data(forKey: Self.placesKey).flatMap { try? JSONDecoder().decode([ClockPlace].self, from: $0) }) ?? []
        showInMenuBar = defaults.bool(forKey: Self.barKey)
        twentyFourHour = defaults.bool(forKey: Self.hourKey)
    }

    private func save() { if let data = try? JSONEncoder().encode(places) { defaults.set(data, forKey: Self.placesKey) } }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.now = Date() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshEvents() { events = Array((meetings?.today() ?? []).prefix(6)) }

    @discardableResult
    func add(named name: String) -> Bool {
        guard let zone = TimeZoneTool.zone(named: name), !places.contains(where: { $0.zoneID == zone.identifier }) else { return false }
        places.append(ClockPlace(label: WorldClockFormat.defaultLabel(for: name), zoneID: zone.identifier))
        return true
    }
}

struct WorldClockView: View {
    @ObservedObject var model: WorldClockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.places) { place in
                if let zone = place.zone {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.zoneID.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? place.label).font(.system(size: 13, weight: .medium))
                            Text([WorldClockFormat.dayWord(WorldClockFormat.dayDelta(model.now, in: zone)), WorldClockFormat.difference(model.now, in: zone)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(WorldClockFormat.time(model.now, in: zone, twentyFourHour: model.twentyFourHour, seconds: true)).font(.system(size: 17, weight: .light)).monospacedDigit()
                    }
                }
            }
            if model.places.isEmpty { Text("Add places in Settings › World Clock.").foregroundStyle(.secondary) }
            Divider()
            Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.events.isEmpty { Text("Nothing more on your calendar today.").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                HStack(spacing: 8) {
                    Text(event.start.formatted(date: .omitted, time: .shortened)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(event.title).lineLimit(1)
                    Spacer()
                    if let link = event.link { Button("Join") { NSWorkspace.shared.open(link) }.controlSize(.small) }
                }
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { model.refreshEvents() }
    }
}

final class WorldClockStatusItem: NSObject {
    private let model: WorldClockModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(model: WorldClockModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WorldClockView(model: model))
        model.$showInMenuBar.receive(on: DispatchQueue.main).sink { [weak self] on in self?.setVisible(on) }.store(in: &cancellables)
        model.$now.combineLatest(model.$places, model.$twentyFourHour).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
    }

    private func setVisible(_ on: Bool) {
        if on, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.target = self
            i.button?.action = #selector(clicked(_:))
            i.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            item = i
            refresh()
        } else if !on, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let text = WorldClockFormat.barText(model.places, date: model.now, twentyFourHour: model.twentyFourHour)
        let shown = text.isEmpty ? "Clock" : text
        if button.title != shown { button.title = shown }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) } else { popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY) }
    }
}
