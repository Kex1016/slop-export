import AppKit
import Charts
import SlopCore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 6: compares Bridge, the export, the Apple Mail folders and iCloud, folder by folder.
struct VerifyView: View {
    @Environment(AppModel.self) private var model
    @State private var exporting: ReportDocument?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Compare with Bridge's live counts", isOn: $model.verifyBridge)
                            .disabled(!model.canVerifyBridge)
                        Toggle("Compare with iCloud Mail", isOn: $model.verifyICloud)
                            .disabled(!model.canVerifyICloud)
                        Text("Only reads. Without Bridge, the counts from the last export scan are used. The Apple Mail folders are checked when they have been built.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            if model.isVerifying { ProgressView().controlSize(.small).accessibilityLabel("Verifying") }
                            Spacer()
                            Button("Verify") { model.runVerify() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!model.canVerify)
                                .accessibilityIdentifier("verify-button")
                        }
                    }
                    .padding(4)
                }

                if let report = model.verifyReport {
                    VerifyResultView(report: report)
                    HStack {
                        Spacer()
                        Button("Save as HTML…") { exporting = ReportDocument(report: report, type: .html) }
                        Button("Save as Text…") { exporting = ReportDocument(report: report, type: .plainText) }
                    }
                } else if !model.hasExistingExport {
                    ContentUnavailableView("No export yet", systemImage: Step.verify.symbol,
                                           description: Text("Run the Export step first."))
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Verify")
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: exporting?.type ?? .html,
                      defaultFilename: "slop-export verify report") { result in
            if case .failure(let error) = result { model.errors[.verify] = error.localizedDescription }
        }
    }
}

struct ReportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.html, .plainText]
    let text: String
    let type: UTType

    init(report: VerifyReport, type: UTType) {
        self.type = type
        text = type == .html ? VerifyFormatter.html(report) : VerifyFormatter.text(report)
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Result

struct VerifyResultView: View {
    let report: VerifyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StatusBanner(report: report)

            HStack(spacing: 12) {
                StatTile(title: "All Mail on Bridge", value: report.allMailCount.map { $0.formatted() } ?? "–")
                StatTile(title: "All Mail in the store", value: report.allMailAccountedFor.formatted())
                StatTile(title: "Distinct messages", value: report.distinctMessages.formatted())
                if report.icloudComplete != nil {
                    StatTile(title: "Missing in iCloud",
                             value: report.targets.reduce(0) { $0 + $1.missingInICloud.count }.formatted())
                }
            }

            FolderChart(report: report)

            VStack(alignment: .leading, spacing: 6) {
                Text("Folders").font(.headline)
                FolderTable(report: report)
            }

            let missing = report.targets.flatMap { row in row.missingInICloud.map { (folder: row.folder, message: $0) } }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Missing in iCloud").font(.headline)
                    ForEach(Array(missing.enumerated()), id: \.offset) { _, item in
                        Text("\(item.folder): \(item.message.messageID ?? "(no Message-ID)")")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            if !report.skipped.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Skipped on Bridge").font(.headline)
                    ForEach(report.skipped, id: \.self) { skip in
                        Text("\(skip.mailbox) UID \(skip.uid): \(skip.reason)").font(.callout)
                    }
                }
            }
        }
    }
}

/// Pass/fail with an icon and words, never colour alone.
struct StatusBanner: View {
    let report: VerifyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.passed ? "Everything is accounted for" : "Something is missing",
                  systemImage: report.passed ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(report.passed ? Palette.good : Palette.critical)
            ForEach(VerifyFormatter.problems(report), id: \.self) { problem in
                Text(problem)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart

/// Grouped horizontal bars: per folder, how many messages should be there and how many each
/// output holds. Colours follow the series (expected, Apple Mail, iCloud), never rank.
struct FolderChart: View {
    let report: VerifyReport
    @State private var hovered: String?

    struct Point: Identifiable {
        var id: String { folder + series }
        let folder: String
        let series: String
        let count: Int
    }

    private var series: [String] {
        var out = ["Expected"]
        if report.targets.contains(where: { $0.mbox != nil }) { out.append("Apple Mail") }
        if report.targets.contains(where: { $0.icloud != nil }) { out.append("iCloud") }
        return out
    }

    private var points: [Point] {
        report.targets.flatMap { row -> [Point] in
            var out = [Point(folder: row.folder, series: "Expected", count: row.expected)]
            if let mbox = row.mbox { out.append(Point(folder: row.folder, series: "Apple Mail", count: mbox)) }
            if let icloud = row.icloud {
                // Only what was expected and found, so extra mail already in iCloud does not hide a gap.
                out.append(Point(folder: row.folder, series: "iCloud", count: row.expected - row.missingInICloud.count))
            }
            return out
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Messages per folder").font(.headline)
            Chart(points) { point in
                BarMark(x: .value("Messages", point.count), y: .value("Folder", point.folder))
                    .position(by: .value("Output", point.series), axis: .vertical)
                    .foregroundStyle(by: .value("Output", point.series))
                    .cornerRadius(4)
                    .opacity(hovered == nil || hovered == point.folder ? 1 : 0.35)
            }
            .chartForegroundStyleScale(domain: series, range: series.map(Palette.series))
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let y = location.y - geo[frame].origin.y
                                hovered = proxy.value(atY: y, as: String.self)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: CGFloat(max(report.targets.count, 1)) * CGFloat(series.count * 10 + 16) + 40)
            .accessibilityLabel("Messages per folder: expected compared with each output. The table below has the same numbers.")

            Group {
                if let hovered, let row = report.targets.first(where: { $0.folder == hovered }) {
                    Text(tooltip(row))
                } else {
                    Text("Hover over a folder to see its numbers.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func tooltip(_ row: VerifyReport.TargetRow) -> String {
        var parts = ["\(row.folder): \(row.expected) expected"]
        if let mbox = row.mbox { parts.append("\(mbox) in Apple Mail") }
        if row.icloud != nil {
            parts.append("\(row.expected - row.missingInICloud.count) in iCloud")
            if row.extraInICloud > 0 { parts.append("\(row.extraInICloud) other messages already there") }
        }
        return parts.joined(separator: ", ")
    }
}

/// The same numbers as the chart, as text (needed for VoiceOver and for the low-contrast series).
struct FolderTable: View {
    let report: VerifyReport

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("Folder").gridColumnAlignment(.leading)
                Text("Expected")
                Text("Apple Mail")
                Text("iCloud")
                Text("Missing")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(report.targets) { row in
                GridRow {
                    Text(row.folder)
                    Text(row.expected.formatted())
                    cell(row.mbox, bad: row.mbox.map { $0 != row.expected } ?? false)
                    cell(row.icloud.map { _ in row.expected - row.missingInICloud.count }, bad: !row.missingInICloud.isEmpty)
                    cell(row.icloud.map { _ in row.missingInICloud.count }, bad: !row.missingInICloud.isEmpty)
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func cell(_ value: Int?, bad: Bool) -> some View {
        if let value {
            HStack(spacing: 4) {
                if bad { ErrorIcon() }
                Text(value.formatted())
            }
        } else {
            Text("–").foregroundStyle(.tertiary)
        }
    }
}

/// Data-viz palette (dataviz skill reference palette, first three categorical slots, validated
/// for colour-blind separation in light and dark; light aqua is under 3:1, so the table repeats
/// every number).
enum Palette {
    static func series(_ name: String) -> Color {
        switch name {
        case "Expected": dynamic(light: 0x2A78D6, dark: 0x3987E5)
        case "Apple Mail": dynamic(light: 0xEB6834, dark: 0xD95926)
        default: dynamic(light: 0x1BAF7A, dark: 0x199E70)
        }
    }

    static let good = dynamic(light: 0x0CA30C, dark: 0x0CA30C)
    static let critical = dynamic(light: 0xD03B3B, dark: 0xD03B3B)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
