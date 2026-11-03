import AppKit
import SwiftUI

/// One transcript paragraph as native text: select and copy it like any text, click a word to play
/// from where it was said, and watch the word being spoken light up.
///
/// AppKit rather than a SwiftUI `Text` of links, so that copying gives plain text (no app links pasted
/// into an email), a selection survives while the paragraph plays (only the lit word's attributes
/// change), and VoiceOver reads a paragraph rather than a list of links.
struct TranscriptParagraph: NSViewRepresentable {
    let utterance: Utterance
    /// The word being spoken, if this paragraph is playing.
    let lit: Int?
    let query: String
    /// Space, ↑ and ↓ while this paragraph has keyboard focus (after you click in it).
    var onKey: ((TranscriptKey) -> Void)?
    /// Keyboard focus arrived in or left this paragraph.
    var onFocus: ((Bool) -> Void)?
    let onPlay: (Double) -> Void

    static let maxWidth: CGFloat = 720
    static let lineSpacing: CGFloat = 3

    func makeNSView(context: Context) -> WordTextView {
        let view = WordTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setAccessibilityHelp("Click a word to play from there")
        return view
    }

    func updateNSView(_ view: WordTextView, context: Context) {
        view.onPlay = onPlay
        view.onKey = onKey
        view.onFocus = onFocus
        view.show(utterance, query: query)
        view.light(lit)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: WordTextView, context: Context) -> CGSize? {
        let width = min(proposal.width ?? Self.maxWidth, Self.maxWidth)
        guard width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: view.height(forWidth: width))
    }
}

enum TranscriptKey { case playPause, previous, next }

final class WordTextView: NSTextView {
    var onPlay: ((Double) -> Void)?
    var onKey: ((TranscriptKey) -> Void)?
    var onFocus: ((Bool) -> Void)?
    private var contentKey = ""
    private var wordRanges: [NSRange] = []
    private var wordStarts: [Double] = []
    private var litIndex: Int?
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0

    /// Shown until the first word is clicked, then the paragraphs stop explaining themselves.
    private static let hintKey = "transcript.clickWordHintSeen"

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = TranscriptParagraph.lineSpacing
        return [.font: Theme.NS.body, .foregroundColor: Theme.NS.ink, .paragraphStyle: paragraph]
    }

    func show(_ u: Utterance, query: String) {
        let key = "\(u.id)\u{1}\(u.words.first?.start ?? -1)\u{1}\(query)\u{1}\(u.text)"
        guard key != contentKey else { return }
        contentKey = key
        litIndex = nil
        wordRanges = []
        wordStarts = []

        let text = NSMutableAttributedString()
        // Words with their own times, unless the text was edited out of step with them.
        if !u.words.isEmpty, u.words.map(\.text).joined(separator: " ") == u.text {
            for (i, w) in u.words.enumerated() {
                if i > 0 { text.append(NSAttributedString(string: " ", attributes: Self.baseAttributes)) }
                wordRanges.append(NSRange(location: text.length, length: (w.text as NSString).length))
                wordStarts.append(w.start)
                text.append(NSAttributedString(string: w.text, attributes: Self.baseAttributes))
            }
        } else {
            text.append(NSAttributedString(string: u.text, attributes: Self.baseAttributes))
            if let first = u.words.first { wordRanges = [NSRange(location: 0, length: text.length)]; wordStarts = [first.start] }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let plain = text.string as NSString
            var search = NSRange(location: 0, length: plain.length)
            while true {
                let found = plain.range(of: q, options: .caseInsensitive, range: search)
                guard found.location != NSNotFound else { break }
                text.addAttribute(.backgroundColor, value: Theme.NS.searchWash, range: found)
                let next = found.location + max(found.length, 1)
                search = NSRange(location: next, length: plain.length - next)
            }
        }
        textStorage?.setAttributedString(text)
        measuredWidth = 0
        window?.invalidateCursorRects(for: self)
        toolTip = UserDefaults.standard.bool(forKey: Self.hintKey) ? nil : "Click a word to play from there"
    }

    /// Lights one word (or none). Only that word's attributes change, so a selection stays put.
    func light(_ index: Int?) {
        let target = index.flatMap { $0 < wordRanges.count ? $0 : nil }
        guard target != litIndex, let storage = textStorage else { return }
        storage.beginEditing()
        if let old = litIndex, old < wordRanges.count {
            storage.addAttribute(.foregroundColor, value: Theme.NS.ink, range: wordRanges[old])
            storage.removeAttribute(.backgroundColor, range: wordRanges[old])
            storage.removeAttribute(.underlineStyle, range: wordRanges[old])
        }
        if let new = target {
            storage.addAttribute(.foregroundColor, value: Theme.NS.signalText, range: wordRanges[new])
            storage.addAttribute(.backgroundColor, value: Theme.NS.signalWash, range: wordRanges[new])
            // A cue that doesn't rely on colour alone, and doesn't move the text.
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: wordRanges[new])
            storage.addAttribute(.underlineColor, value: Theme.NS.signal, range: wordRanges[new])
        }
        storage.endEditing()
        litIndex = target
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        if abs(width - measuredWidth) < 0.5 { return measuredHeight }
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        measuredWidth = width
        measuredHeight = ceil(layout.usedRect(for: container).height)
        window?.invalidateCursorRects(for: self)
        return measuredHeight
    }

    // MARK: Clicking a word

    override func mouseDown(with event: NSEvent) {
        let hadSelection = selectedRange().length > 0
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event) // tracks a drag-to-select until the mouse goes up
        // A plain click on a word plays from it. A drag selects, a double-click selects a word, and a click
        // that only clears a selection does just that.
        guard event.clickCount == 1, !hadSelection, selectedRange().length == 0,
              let start = wordStart(at: point) else { return }
        UserDefaults.standard.set(true, forKey: Self.hintKey)
        toolTip = nil
        onPlay?(start)
    }

    /// A pointing hand over the words says they can be clicked (a drag still selects).
    override func resetCursorRects() {
        guard let layout = layoutManager, let container = textContainer else { return }
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            self.addCursorRect(used, cursor: .pointingHand)
        }
    }

    func wordStart(at point: NSPoint) -> Double? {
        guard let layout = layoutManager, let container = textContainer, !wordRanges.isEmpty else { return nil }
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        // Only when the pointer is over a glyph, not past the end of a line.
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -2, dy: -2).contains(point)
        else { return nil }
        let char = layout.characterIndexForGlyph(at: glyph)
        // The word containing the character, or the one after a space.
        guard let i = wordRanges.firstIndex(where: { NSMaxRange($0) > char }) else { return nil }
        return wordStarts[i]
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    /// Clicking a word gives this paragraph keyboard focus; the transcript's keys keep working from here.
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, let onKey {
            switch event.keyCode {
            case 49: onKey(.playPause); return  // Space
            case 126: onKey(.previous); return  // ↑
            case 125: onKey(.next); return      // ↓
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Copying gives plain text

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Copy, drag and Services all write the selected words as plain text.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString((string as NSString).substring(with: range), forType: .string)
    }

    override func copy(_ sender: Any?) {
        _ = writeSelection(to: .general, types: [.string])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // The paragraph's own context menu (Play from here, Copy paragraph…) comes from SwiftUI.
        nil
    }
}
