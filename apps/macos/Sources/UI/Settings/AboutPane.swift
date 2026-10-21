import AppKit
import SwiftUI

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Kriya").font(.largeTitle.bold())
            Text("Version \(SystemInfo.appVersion) (\(SystemInfo.build))")
                .foregroundStyle(.secondary)
            Text("Mouse, trackpad, window and right-click control for your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Core \(coreVersion()) · \(SystemInfo.architecture)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
