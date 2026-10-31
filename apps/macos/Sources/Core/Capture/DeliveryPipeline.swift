import Foundation

/// The stages of delivering a capture. They always run in this order, whatever was asked for: only the ones asked for run.
enum DeliveryStage: Int, CaseIterable, Comparable, Equatable {
    /// 1. Write the output: into the capture folder when it is to be kept, otherwise to a temporary file.
    case saveTemporaryOutput = 1
    /// 2. Copy it.
    case copy
    /// 3. Upload it.
    case upload
    /// 4. Put a link to it on the clipboard.
    case createLink
    /// 5. Open the editor on it.
    case openEditor
    /// 6. Pin it on the screen.
    case pin
    /// 7. Show its Quick Access card.
    case createQuickAccessCard
    /// 8. Remove the temporary files.
    case removeTemporaryFiles

    static func < (a: DeliveryStage, b: DeliveryStage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .saveTemporaryOutput: return "Save the output"
        case .copy: return "Copy"
        case .upload: return "Upload"
        case .createLink: return "Create a link"
        case .openEditor: return "Open the editor"
        case .pin: return "Pin"
        case .createQuickAccessCard: return "Show the Quick Access card"
        case .removeTemporaryFiles: return "Remove temporary files"
        }
    }
}

/// A file the output was written to, and whether it is only there for the delivery (and so removed at the end).
struct DeliveredFile: Equatable {
    var url: URL
    var isTemporary: Bool
}

enum UploadResult: Equatable {
    case uploaded(link: String)
    case failed(String)
}

/// What the pipeline asks the app to do at each stage. The app does the work; a check records what was asked and in what order. The
/// clipboard, windows and cards belong to the main thread, so every stage runs there.
@MainActor
protocol DeliveryActions: AnyObject {
    /// 1. Writes the output, in the capture folder when `permanent`, otherwise to a temporary file. Nil if it could not be written.
    func saveOutput(permanent: Bool) -> DeliveredFile?
    /// 2. Copies it. Returns a sentence when the copy was not what was chosen, or nil.
    func copy(file: URL?) -> String?
    /// 3. Uploads the file.
    func upload(file: URL) async -> UploadResult
    /// 4. Puts a link on the clipboard: the uploaded one if there is one, otherwise one to the kept file. Returns the link, or nil if none could be made.
    func copyLink(uploaded: String?, keptFile: URL?) -> String?
    /// 5. Opens the editor on the picture.
    func openEditor()
    /// 6. Pins the picture.
    func pin()
    /// 7. Shows the card. `keptFile` is the file that stays, if there is one (never a temporary one).
    func showQuickAccessCard(keptFile: URL?)
    /// 8. Removes the files that were only there for the delivery.
    func removeTemporary(_ files: [URL])
}

/// What one delivery is asked to do.
struct DeliveryJob: Equatable {
    var kind: CaptureKind
    var steps: DeliverySteps
    /// Copying puts the file on the clipboard (not only the picture), so a file has to exist first.
    var copyNeedsFile = false
}

/// What was done, in the order it was done.
struct DeliveryReport: Equatable {
    var stages: [DeliveryStage] = []
    var messages: [String] = []
    /// The file that was kept, if the output was saved for keeps.
    var keptFile: URL?
    var link: String?
}

enum DeliveryPipeline {
    /// The stages that will run for this job, in the fixed order.
    static func stages(for job: DeliveryJob) -> [DeliveryStage] {
        let steps = job.steps.normalized(for: job.kind, keepsSomething: false)
        var planned: [DeliveryStage] = []
        let needsOutput = steps.save || steps.upload || steps.copyLink || (steps.copy && job.copyNeedsFile)
        if needsOutput { planned.append(.saveTemporaryOutput) }
        if steps.copy { planned.append(.copy) }
        if steps.upload { planned.append(.upload) }
        if steps.copyLink { planned.append(.createLink) }
        if steps.annotate { planned.append(.openEditor) }
        if steps.pin { planned.append(.pin) }
        if steps.showQuickAccessCard { planned.append(.createQuickAccessCard) }
        // Cleaning up only follows an output that was written only for the delivery; it is decided when the output exists.
        if needsOutput, !steps.save { planned.append(.removeTemporaryFiles) }
        return planned.sorted()
    }

    /// Runs the stages in order. A stage that cannot do its work says so in the report and the rest go on: a failed upload does not stop
    /// the copy that came before it, or the card that comes after.
    @MainActor
    static func run(_ job: DeliveryJob, actions: DeliveryActions) async -> DeliveryReport {
        let steps = job.steps.normalized(for: job.kind, keepsSomething: false)
        var report = DeliveryReport()
        var file: DeliveredFile?
        var uploaded: String?
        for stage in stages(for: job) {
            switch stage {
            case .saveTemporaryOutput:
                file = actions.saveOutput(permanent: steps.save)
                if file == nil { report.messages.append("The output could not be written.") }
                report.keptFile = file.flatMap { $0.isTemporary ? nil : $0.url }
                report.stages.append(stage)
            case .copy:
                if let note = actions.copy(file: file?.url) { report.messages.append(note) }
                report.stages.append(stage)
            case .upload:
                if let target = file {
                    switch await actions.upload(file: target.url) {
                    case .uploaded(let link): uploaded = link
                    case .failed(let reason): report.messages.append(reason)
                    }
                } else {
                    report.messages.append("Nothing was uploaded: there was no file to upload.")
                }
                report.stages.append(stage)
            case .createLink:
                report.link = actions.copyLink(uploaded: uploaded, keptFile: report.keptFile)
                if report.link == nil { report.messages.append("No link could be made: the capture was not uploaded or saved.") }
                report.stages.append(stage)
            case .openEditor:
                actions.openEditor()
                report.stages.append(stage)
            case .pin:
                actions.pin()
                report.stages.append(stage)
            case .createQuickAccessCard:
                actions.showQuickAccessCard(keptFile: report.keptFile)
                report.stages.append(stage)
            case .removeTemporaryFiles:
                if let temporary = file, temporary.isTemporary {
                    actions.removeTemporary([temporary.url])
                    report.stages.append(stage)
                }
            }
        }
        return report
    }
}
