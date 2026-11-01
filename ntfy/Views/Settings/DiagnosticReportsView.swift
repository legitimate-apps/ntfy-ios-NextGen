import SwiftUI

struct DiagnosticReportsView: View {
    @State private var reports: [DiagnosticReport] = []
    @State private var failed = false

    var body: some View {
        List {
            Section(footer: Text(String(localized: "Reports stay on this device until you share them. Message content, topic names, server addresses and credentials are excluded. Up to 20 reports are kept for 30 days, within 10 MB."))) {
                if reports.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "No diagnostic reports"))
                            .font(.headline)
                        Text(String(localized: "iOS provides reports after some crashes, hangs or resource issues. They may arrive later and do not cover every incident."))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(reports) { report in
                    NavigationLink {
                        DiagnosticReportView(report: report, onDelete: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.kind.title)
                            Text(report.date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundColor(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("diagnostic-" + report.kind.rawValue)
                }
                .onDelete { offsets in
                    do {
                        for index in offsets { try DiagnosticReportStore.shared.delete(reports[index]) }
                        reload()
                    } catch { failed = true }
                }
            }
        }
        .navigationTitle(String(localized: "Diagnostic reports"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: DiagnosticReportStore.changed)) { _ in reload() }
        .alert(String(localized: "Could not access reports"), isPresented: $failed) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Please try again after unlocking your device or freeing storage space."))
        }
    }

    private func reload() {
        do { reports = try DiagnosticReportStore.shared.reports() }
        catch { failed = true }
    }
}

private struct DiagnosticReportView: View {
    let report: DiagnosticReport
    let onDelete: () -> Void
    @Environment(\.presentationMode) private var presentationMode
    @State private var share: ReportFile?
    @State private var confirmingDelete = false
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Text(report.kind.title).font(.headline)
                Text(report.date.formatted(date: .long, time: .shortened))
            } footer: {
                Text(String(localized: "Date shown is the end of the iOS reporting period. The JSON file contains call stacks and technical metadata. You can attach it to a bug report."))
            }
            Section {
                Button {
                    do { share = ReportFile(url: try DiagnosticReportStore.shared.file(for: report)) }
                    catch { failed = true }
                } label: {
                    Label(String(localized: "Share report"), systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(String(localized: "Delete report"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(report.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { DiagnosticShareSheet(url: $0.url) }
        .confirmationDialog(String(localized: "Delete report?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete report"), role: .destructive) {
                do {
                    try DiagnosticReportStore.shared.delete(report)
                    onDelete()
                    presentationMode.wrappedValue.dismiss()
                } catch { failed = true }
            }
        }
        .alert(String(localized: "Could not access reports"), isPresented: $failed) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Please try again after unlocking your device or freeing storage space."))
        }
    }
}

private struct ReportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
