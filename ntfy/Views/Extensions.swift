import SwiftUI
import UIKit

// MARK: Extensions

extension Notification {
    /// Body for display: rendered Markdown when the message is `text/markdown`
    /// (ntfy #1072), otherwise plain text with detected links made tappable.
    func renderedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: contentType)
    }

    func linkifiedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: nil)
    }
}

/// Pure + testable. Parses Markdown (iOS 15+) when `contentType` is
/// `text/markdown`; otherwise linkifies plain text via `linkify()`. Markdown
/// failures fall back to the linkified plain text so a malformed body never
/// renders empty.
func renderMessageBody(_ source: String, contentType: String?) -> AttributedString {
    if #available(iOS 15.0, *), contentType == "text/markdown" {
        if var attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)) {
            // Foundation's markdown parser only links [text](url)/<url>, never a bare
            // "https://…", so a bare URL in a markdown message rendered dead while the
            // exact same text as plain text was tappable. Run the same detector pass the
            // plain-text path uses over the parsed runs to close that gap (ntfy #1743).
            linkifyBareUrls(in: &attributed)
            return attributed
        }
    }
    // Plain-text path: full-range link styling (ntfy #1743) via the shared linkify().
    return linkify(source)
}

/// Add tappable + styled links to any bare URL in an already-parsed AttributedString
/// (e.g. markdown output), WITHOUT disturbing existing runs. Ranges that already carry
/// a `.link` (markdown-authored links) are left untouched so their target/label survive.
/// Operates purely on the Swift AttributedString so no markdown styling is ever lost.
func linkifyBareUrls(in attributed: inout AttributedString) {
    let text = String(attributed.characters)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: (text as NSString).length)
    detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
        guard let match, let url = match.url, let strRange = Range(match.range, in: text) else { return }
        let start = text.distance(from: text.startIndex, to: strRange.lowerBound)
        let length = text.distance(from: strRange.lowerBound, to: strRange.upperBound)
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(lower, offsetByCharacters: length)
        let attrRange = lower..<upper
        guard attributed[attrRange].link == nil else { return }  // keep markdown-authored links
        attributed[attrRange].link = url
        attributed[attrRange].foregroundColor = UIColor.link
        attributed[attrRange].underlineStyle = NSUnderlineStyle.single
    }
}

/// Detect links in `source` and return an AttributedString with each link made
/// tappable AND fully styled (color + underline) across its ENTIRE range.
///
/// Setting only `.link` and letting SwiftUI apply the implicit link styling
/// truncated the coloring/underline of long or line-wrapping URLs to the
/// recognized prefix (ntfy iOS #1743). Applying `.foregroundColor` and
/// `.underlineStyle` explicitly over the full detector match keeps the whole
/// URL visibly a link. Pure + free-standing so it's unit-testable without a
/// Core Data Notification.
func linkify(_ source: String) -> AttributedString {
    let mutable = NSMutableAttributedString(string: source)
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(location: 0, length: mutable.string.utf16.count)
    detector?.enumerateMatches(in: mutable.string, options: [], range: range) { match, _, _ in
        guard let match, let url = match.url else { return }
        mutable.addAttribute(.link, value: url, range: match.range)
        mutable.addAttribute(.foregroundColor, value: UIColor.link, range: match.range)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
    }
    return AttributedString(mutable)
}

// MARK: Selectable message text

struct MessageRowTapPolicy: Equatable {
    let installsAncestorContentTap: Bool
    let installsRegionTaps: Bool
}

/// Keeps row-level tap ownership testable without constructing SwiftUI's view tree.
/// Text views route their own link/plain taps, so an ancestor recognizer must
/// never independently trigger the row action after UIKit opens a link.
func messageRowTapPolicy(isEditing: Bool) -> MessageRowTapPolicy {
    return MessageRowTapPolicy(
        installsAncestorContentTap: false,
        installsRegionTaps: !isEditing
    )
}

enum MessageTextStyle {
    case body
    case title

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .body:
            return .body
        case .title:
            return .headline
        }
    }

    var baseTraits: UIFontDescriptor.SymbolicTraits {
        switch self {
        case .body:
            return []
        case .title:
            return .traitBold
        }
    }
}

/// Title rendering shares the body's URL detector so links behave consistently
/// in both visible message fields.
func renderMessageTitle(_ source: String) -> AttributedString {
    return linkify(source)
}

/// Converts the SwiftUI-oriented attributed value into attributes UIKit can
/// render directly. UIKit's NSAttributedString bridge does not interpret
/// Markdown presentation intents, so resolve those intents into real fonts.
func makeMessageNSAttributedString(
    _ attributed: AttributedString,
    style: MessageTextStyle
) -> NSAttributedString {
    let bridged = NSAttributedString(attributed)
    let output = NSMutableAttributedString(
        string: bridged.string,
        attributes: [.foregroundColor: UIColor.label]
    )
    let fullRange = NSRange(location: 0, length: bridged.length)
    bridged.enumerateAttributes(in: fullRange) { attributes, range, _ in
        output.addAttributes(attributes, range: range)
    }

    let plainText = String(attributed.characters)
    for run in attributed.runs {
        let lowerOffset = attributed.characters.distance(
            from: attributed.startIndex,
            to: run.range.lowerBound
        )
        let upperOffset = attributed.characters.distance(
            from: attributed.startIndex,
            to: run.range.upperBound
        )
        let lower = plainText.index(plainText.startIndex, offsetBy: lowerOffset)
        let upper = plainText.index(plainText.startIndex, offsetBy: upperOffset)
        let range = NSRange(lower..<upper, in: plainText)

        var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style.uiTextStyle)
        var traits = descriptor.symbolicTraits.union(style.baseTraits)
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.stronglyEmphasized) {
                traits.insert(.traitBold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.traitItalic)
            }
            if intent.contains(.code) {
                descriptor = descriptor.withDesign(.monospaced) ?? descriptor
            }
        }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        output.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
    }

    return output
}

/// Applies the canonical interaction and sizing configuration used by both the
/// title and body wrappers.
func configureMessageTextView(
    _ textView: UITextView,
    isInteractionEnabled: Bool
) {
    textView.isSelectable = true
    textView.isEditable = false
    textView.accessibilityTraits.insert(.staticText)
    textView.isScrollEnabled = false
    textView.adjustsFontForContentSizeCategory = true
    textView.isUserInteractionEnabled = isInteractionEnabled
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.tintColor = .link
    textView.linkTextAttributes = [
        .foregroundColor: UIColor.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.setContentHuggingPriority(.required, for: .vertical)
}

// MARK: Wrapping without hyphenation

/// Width of the widest whitespace-delimited token, measured with the attributes
/// the token is actually drawn with. A "token" here is deliberately not a
/// linguistic word: an API key, a URL or a base64 blob is one token, and it is
/// exactly those that the line breaker cannot fit.
func widestTokenWidth(in attributed: NSAttributedString) -> CGFloat {
    let text = attributed.string as NSString
    let whitespace = CharacterSet.whitespacesAndNewlines
    var widest: CGFloat = 0
    var index = 0
    while index < text.length {
        var end = index
        while end < text.length,
              let scalar = Unicode.Scalar(text.character(at: end)),
              !whitespace.contains(scalar) {
            end += 1
        }
        if end > index {
            let token = attributed.attributedSubstring(from: NSRange(location: index, length: end - index))
            widest = max(widest, token.size().width)
            index = end
        } else {
            index += 1
        }
    }
    return widest
}

/// TextKit 2 inserts a hyphen when word wrapping has to break inside a single
/// word that cannot fit the line, so a 64-character API token renders as
/// `…b32e-` / `fa674…` — and whoever reads it off the screen carries away a
/// character the message never contained. Measured on iOS 26.5: neither
/// `hyphenationFactor = 0` nor `usesDefaultHyphenation = false` suppresses it,
/// and `NSTextContainer.lineBreakMode` is ignored outright. Character wrapping
/// is the only mode that never inserts one, but it also breaks ordinary prose
/// mid-word ("succ/essfully"), so a paragraph earns it only when that paragraph
/// really does hold a token wider than the line it has to fit in.
func messageLineBreakMode(widestTokenWidth: CGFloat, availableWidth: CGFloat) -> NSLineBreakMode {
    guard availableWidth > 0, widestTokenWidth > availableWidth else {
        return .byWordWrapping
    }
    return .byCharWrapping
}

/// Gives every paragraph the line-break mode it needs at this width, preserving
/// any other paragraph attributes the Markdown parser produced. The hyphenation
/// properties are set too: they do not suppress the inserted hyphen on their own
/// (that is what the mode is for), but they state the intent for any renderer
/// that does honor them.
func applyMessageWrapping(to attributed: NSAttributedString, availableWidth: CGFloat) -> NSAttributedString {
    guard attributed.length > 0 else {
        return attributed
    }
    let output = NSMutableAttributedString(attributedString: attributed)
    let text = output.string as NSString
    text.enumerateSubstrings(
        in: NSRange(location: 0, length: text.length),
        options: [.byParagraphs, .substringNotRequired]
    ) { _, _, enclosingRange, _ in
        guard enclosingRange.length > 0 else { return }
        let paragraph = output.attributedSubstring(from: enclosingRange)
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = messageLineBreakMode(
            widestTokenWidth: widestTokenWidth(in: paragraph),
            availableWidth: availableWidth
        )
        style.hyphenationFactor = 0
        if #available(iOS 15.0, *) {
            style.usesDefaultHyphenation = false
        }
        output.addAttribute(.paragraphStyle, value: style, range: enclosingRange)
    }
    return output
}

/// A self-sizing, non-scrolling text view that re-decides how to wrap whenever
/// its width changes. It keeps the message it was given, so the wrapping
/// decision is always recomputed from the original text rather than compounded
/// on top of the last decision.
final class MessageTextView: UITextView {
    private var lastLaidOutWidth: CGFloat = 0
    private var messageText: NSAttributedString?
    private var wrappedWidth: CGFloat = -1

    /// The width text actually gets to occupy, which is what the wrapping
    /// decision has to be made against — not the view's own bounds.
    var availableTextWidth: CGFloat {
        let insets = textContainerInset.left + textContainerInset.right
        let padding = textContainer.lineFragmentPadding * 2
        return max(0, bounds.width - insets - padding)
    }

    func setMessageText(_ next: NSAttributedString) {
        guard messageText?.isEqual(to: next) != true else {
            return
        }
        messageText = next
        wrappedWidth = -1
        applyWrapping()
    }

    private func applyWrapping() {
        guard let messageText else {
            return
        }
        let width = availableTextWidth
        guard abs(width - wrappedWidth) > 0.5 else {
            return
        }
        wrappedWidth = width
        let wrapped = applyMessageWrapping(to: messageText, availableWidth: width)
        guard !attributedText.isEqual(to: wrapped) else {
            return
        }
        let selection = selectedRange
        attributedText = wrapped
        if NSMaxRange(selection) <= wrapped.length {
            selectedRange = selection
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else {
            return super.intrinsicContentSize
        }
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 1)
        }
        let fittingSize = sizeThatFits(
            CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fittingSize.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyWrapping()
        guard abs(bounds.width - lastLaidOutWidth) > 0.5 else {
            return
        }
        lastLaidOutWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

@available(iOS 17.0, *)
func preservedDefaultLinkMenu(_ defaultMenu: UIMenu) -> UIMenu {
    return defaultMenu
}

// MARK: Modifiers

struct DisableAutocapitalizationModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .textInputAutocapitalization(.never)
        } else {
            content
                .autocapitalization(.none)
        }
    }
}

extension View {
    func disableAutocapitalization() -> some View {
        modifier(DisableAutocapitalizationModifier())
    }
}
