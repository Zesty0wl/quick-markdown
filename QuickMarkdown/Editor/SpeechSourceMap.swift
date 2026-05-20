import Foundation

/// Maps word ranges in a *rendered plain-text* string back to the corresponding
/// word ranges in the *markdown source* it was rendered from.
///
/// Approach: tokenise both strings into word runs (`\w+`) and pair them
/// greedily in order. Markdown syntax characters (`*`, `_`, `#`, `[`, `]`,
/// `(`, `)`, `` ` ``, `|`, `>`) and image/link URLs aren't word characters,
/// so for almost every document the i-th word in the source that survives
/// rendering lines up with the i-th word in the rendered output. Source-only
/// words (front-matter values, link URLs, image source paths) are skipped
/// when we can't find a match.
///
/// Used by the read-aloud feature to highlight the currently-spoken word in
/// the markdown source editor (where a per-character rendered → source map
/// is otherwise impractical because the renderer collapses arbitrary syntax).
struct SpeechSourceMap {

    /// A single word that exists in both the rendered output and the source.
    /// `rendered` indexes into the rendered plain-text string handed to the
    /// speech synthesiser; `source` indexes into the original markdown.
    struct Span {
        let rendered: NSRange
        let source: NSRange
    }

    let spans: [Span]

    init(source: String, rendered: String) {
        let sourceNS = source as NSString
        let renderedNS = rendered as NSString

        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}]+",
                                                   options: []) else {
            self.spans = []
            return
        }

        let sourceWords = regex.matches(
            in: source,
            options: [],
            range: NSRange(location: 0, length: sourceNS.length)
        )
        let renderedWords = regex.matches(
            in: rendered,
            options: [],
            range: NSRange(location: 0, length: renderedNS.length)
        )

        var result: [Span] = []
        result.reserveCapacity(renderedWords.count)
        var sourceCursor = 0

        for rWord in renderedWords {
            let rText = renderedNS.substring(with: rWord.range)
            let rLower = rText.lowercased()

            // Walk forward in the source word list until we hit a word that
            // equals the rendered word (case-insensitive). Skip every source
            // word we pass over — those are markdown syntax we can't see in
            // the rendered output (front matter values, link URLs, image
            // paths, raw HTML attribute values, …).
            while sourceCursor < sourceWords.count {
                let sWord = sourceWords[sourceCursor]
                let sText = sourceNS.substring(with: sWord.range)
                sourceCursor += 1
                if sText.lowercased() == rLower {
                    result.append(Span(rendered: rWord.range, source: sWord.range))
                    break
                }
            }
        }

        self.spans = result
    }

    /// Translate a range delivered by `AVSpeechSynthesizer.willSpeakRange` to
    /// a range in the markdown source. Returns `nil` when no span covers the
    /// rendered range (e.g. punctuation, or content that has no source twin
    /// such as auto-generated table-of-contents text).
    ///
    /// The synthesiser emits ranges that align with word boundaries in the
    /// rendered string, so we look for the span whose `rendered` range
    /// starts at the requested location. Multi-word spans collapse to a
    /// single source word — accurate enough for live highlighting.
    func sourceRange(for renderedRange: NSRange) -> NSRange? {
        guard renderedRange.location != NSNotFound else { return nil }

        // Binary search for the first span whose rendered.location >= target.
        // Then walk a couple of neighbours to find an exact or near-exact match.
        var lo = 0
        var hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].rendered.location < renderedRange.location {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Exact match wins.
        if lo < spans.count, spans[lo].rendered.location == renderedRange.location {
            return spans[lo].source
        }
        // Otherwise fall back to the span that *contains* the requested
        // location, if any (catches cases where the synthesiser reports a
        // multi-word phrase or a sub-word range).
        let candidate = lo > 0 ? lo - 1 : 0
        if candidate < spans.count {
            let span = spans[candidate]
            let end = span.rendered.location + span.rendered.length
            if renderedRange.location >= span.rendered.location,
               renderedRange.location < end {
                return span.source
            }
        }
        return nil
    }
}
