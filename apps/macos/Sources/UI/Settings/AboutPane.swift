import AppKit
import SwiftUI

struct AboutPane: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var services: ServiceManager
    @EnvironmentObject private var permissions: PermissionManager
    @State private var signing: CodeSignInfo?
    @State private var copied = false

    private var facts: BuildFacts {
        BuildFacts(version: SystemInfo.appVersion, build: SystemInfo.build, commit: Bundle.main.object(forInfoDictionaryKey: "KriyaGitCommit") as? String ?? "not recorded in this build",
                   architecture: SystemInfo.architecture, macOS: SystemInfo.osVersion)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    Text("Kriya").font(.largeTitle.bold())
                    Text("Version \(SystemInfo.appVersion) (\(SystemInfo.build))").foregroundStyle(.secondary)
                    Text("Mouse, trackpad, window and right-click control for your Mac.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                LabeledContent("Commit", value: facts.commit)
                LabeledContent("Core", value: coreVersion())
                LabeledContent("Architecture", value: facts.architecture)
                LabeledContent("macOS", value: facts.macOS)
                LabeledContent("Signature", value: signing?.title ?? "Checking…")
                if let team = signing?.team { LabeledContent("Team", value: team) }
                LabeledContent("Features on", value: featureSummary)
                LabeledContent("Permissions", value: permissionSummary)
                LabeledContent("Recorded on this build", value: evidenceSummary)
                HStack {
                    Button(copied ? "Copied" : "Copy Build Details") { copy() }
                    Button("Open Diagnostics") { navigator.go(.diagnostics, tab: "Health") }
                    Spacer()
                }
            } header: { Text("This build") } footer: {
                Text("The commit is written into the app when it is built. A “+local” after it means there were uncommitted changes. The signature is read from the installed app by macOS.")
            }

            Section {
                LabeledContent("Sparkle 2.10.0", value: "Updates (MIT license)")
                LabeledContent("SQLite (rusqlite)", value: "Storage")
                LabeledContent("UniFFI", value: "Rust to Swift")
                LabeledContent("serde, regex, url, sha2, aes-gcm, hmac", value: "Rust libraries")
            } header: { Text("Made with") } footer: {
                Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: checkSignature)
    }

    private var featureSummary: String {
        let core = FeatureId.all.filter { services.state($0) == .running }.count
        let extra = FeatureRegistry.extras.filter { FeatureSwitchboard.shared.isSwitchable($0.id) && FeatureSwitchboard.shared.isOn($0.id) }.count
        return "\(core) of \(FeatureId.all.count) main, \(extra) more"
    }

    private var permissionSummary: String {
        let granted = Permission.allCases.filter { permissions.isGranted($0) }.count
        return "\(granted) of \(Permission.allCases.count) allowed"
    }

    private var evidenceSummary: String {
        let ids = FeatureId.all.map(\.key) + FeatureRegistry.extras.map(\.id)
        let tested = ids.filter { EvidenceStore.shared.ledger.row(feature: $0, testClasses: [], build: SystemInfo.build).tests == .current }.count
        let hand = ids.filter { EvidenceStore.shared.ledger.row(feature: $0, testClasses: [], build: SystemInfo.build).manual == .current }.count
        return "\(tested) tested, \(hand) tried, of \(ids.count)"
    }

    private func checkSignature() {
        let path = Bundle.main.bundlePath
        DispatchQueue.global(qos: .utility).async {
            func run(_ exe: String, _ args: [String]) -> String {
                do { return try ToolRunner.run(exe, args, timeout: 8) } catch { return (error as? FileActionError)?.message ?? "" }
            }
            // spctl and codesign exit with an error for an unsigned app, and the words are still in what they print.
            let spctl = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", path])
            let codesign = run("/usr/bin/codesign", ["-dv", "--verbose=2", path])
            let info = CodeSignInfo.parse(spctl: spctl, codesign: codesign)
            DispatchQueue.main.async { signing = info }
        }
    }

    private func copy() {
        let text = (facts.lines + ["Signature: \(signing?.title ?? "unknown")", "Features: \(featureSummary)", "Permissions: \(permissionSummary)"]).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
