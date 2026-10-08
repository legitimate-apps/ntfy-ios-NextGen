import SwiftUI

/// An open-source component in the app; MIT, Apache-2.0 and zlib require its notice to ship with it.
struct OpenSourceComponent: Identifiable, Hashable {
    let name: String
    let detail: String
    let licenseName: String
    let notice: String         // copyright line(s), plus the license text when it is short
    let licenseText: String?   // the shared Apache-2.0 text, stored once

    var id: String { name }
    var fullText: String { [notice, licenseText].compactMap { $0 }.joined(separator: "\n\n") }
}

enum OpenSourceLicenses {
    /// License files are hard-wrapped at ~80 columns, which wraps raggedly on a phone. For display,
    /// join the lines of each paragraph; blank lines still separate paragraphs. Words are unchanged.
    static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section(footer: Text("NTFY me is built on these open-source projects.")) {
                ForEach(OpenSourceLicenses.components) { component in
                    NavigationLink {
                        LicenseTextView(text: component.detail + "\n\n" + OpenSourceLicenses.reflowed(component.fullText))
                            .navigationTitle(component.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name)
                            Text(component.licenseName)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
        }
        .navigationTitle("Licenses")
    }
}

/// A read-only UITextView: it scrolls itself, supports selecting any range (SwiftUI's
/// `textSelection` only copies the whole Text), and follows Dynamic Type and dark mode.
private struct LicenseTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .callout)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.accessibilityIdentifier = "licenseText"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
