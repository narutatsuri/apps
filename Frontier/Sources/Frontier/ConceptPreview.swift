import SwiftUI
import WebKit

/// FRONTIER_WEBLOG=1 — narrates the preview's load-and-render pipeline to
/// stderr, because a blank pane has half a dozen distinct causes (load never
/// finished, load failed, JS threw, DOM filled but view invisible) that all
/// look identical from the outside.
func weblog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["FRONTIER_WEBLOG"] == "1" {
        NSLog("WEB %@", message())
    }
}

/// Live markdown + LaTeX preview. KaTeX and marked are bundled into the app rather
/// than loaded from a CDN, so this renders with no network — which matters when the
/// point is to sit and read.
struct ConceptPreview: NSViewRepresentable {
    let markdown: String
    /// The test that goes at the bottom of this page. Rendered in the web view
    /// rather than in SwiftUI so the questions go through the same KaTeX path as
    /// the entry — most of them are about arithmetic, and a question showing
    /// literal dollar signs is not one anyone sits twice.
    var questions: [Concept.Question] = []
    /// Called when the test has been marked, with the score 0…1.
    var onScore: ((Double) -> Void)?
    /// The rendered document's height, reported back after each render. Only the
    /// callers that size themselves to their content pass this; the reading pane
    /// fills the window instead and ignores it.
    var onHeight: ((CGFloat) -> Void)?

    /// Keeps its one subview at its own size through real layout, because an
    /// autoresizing mask applied to a view that started at 0×0 multiplies
    /// zeros and leaves the subview at 0×0 forever.
    final class FillContainer: NSView {
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = FillContainer()
        let configuration = WKWebViewConfiguration()
        // The page posts the answers back here when "Mark my answers" is
        // pressed. A handler rather than pulling them out with
        // evaluateJavaScript, because the page knows when it is finished and
        // Swift would otherwise have to guess.
        configuration.userContentController.add(context.coordinator, name: "frontier")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")   // let SwiftUI's surface show
        view.allowsMagnification = false
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        context.coordinator.webView = view

        guard let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web")
            ?? Bundle.main.url(forResource: "render", withExtension: "html") else {
            view.loadHTMLString("<p>render.html missing from the bundle</p>", baseURL: nil)
            return container
        }
        // Read access to the enclosing directory, so katex.min.js and the fonts resolve.
        context.coordinator.page = html
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = context.coordinator.webView else { return }
        view.frame = container.bounds
        context.coordinator.onHeight = onHeight
        context.coordinator.onScore = onScore
        context.coordinator.pendingQuestions = questions
        context.coordinator.pending = markdown
        context.coordinator.flush(into: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 320)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var pending: String = ""
        var pendingQuestions: [Concept.Question] = []
        var page: URL?
        var onHeight: ((CGFloat) -> Void)?
        var onScore: ((Double) -> Void)?
        weak var webView: WKWebView?
        private var ready = false
        /// The test currently on screen, so a message coming back can be marked
        /// against the questions that were actually asked rather than whatever
        /// the pane has moved on to.
        private var asked: [Concept.Question] = []
        /// What the DOM currently holds. updateNSView fires on any ancestor
        /// state change — a window resize, a sibling's animation — and
        /// re-running marked and KaTeX over a 27,000-character document each
        /// time is both wasteful and, when the caller sizes itself to the
        /// reported height, a loop: render, resize, update, render.
        private var renderedDocument: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            weblog("didFinish — flushing \(pending.count) pending chars")
            ready = true
            renderedDocument = nil
            flush(into: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            weblog("didFail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            weblog("didFailProvisional: \(error.localizedDescription)")
        }

        /// WebKit's content process can die out from under the view — under
        /// memory pressure, or a GPU hiccup — and what that looks like on
        /// screen is the reading pane going permanently, silently blank.
        /// Reload the page; didFinish then replays the pending document.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            renderedDocument = nil
            guard let page else { return }
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        /// Held until the page has loaded, otherwise the first keystrokes are lost.
        func flush(into webView: WKWebView) {
            guard ready else { return }
            guard pending != renderedDocument else { return }
            renderedDocument = pending
            renderTest(into: webView)
            // "└ NVIDIA whitepaper" lines are citations, not prose. Marked up
            // here rather than in the stylesheet, because only this side knows
            // that a line beginning with └ means "where the claim above came
            // from" — and a citation set in body text reads as an afterthought.
            let marked = pending.components(separatedBy: "\n").map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("└") else { return line }
                return "<div class=\"cite\">" + t + "</div>"
            }.joined(separator: "\n")
            let data = (try? JSONSerialization.data(withJSONObject: [marked])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "[\"\"]"
            // Passing through JSON avoids every quoting and newline hazard. The
            // trailing expression hands back the rendered length and the laid-out
            // height, so a failure has an error and a success has numbers — a
            // blank pane stops being indistinguishable from a successful render
            // of nothing, and a caller that sizes to its content has a height to
            // size to.
            webView.evaluateJavaScript(
                "window.renderMarkdown(\(json)[0]);"
                + "[document.getElementById('out').innerHTML.length,"
                + " document.getElementById('out').scrollHeight]"
            ) { [weak self] value, error in
                let pair = value as? [NSNumber]
                weblog("render: out=\(pair?.first.map { "\($0)" } ?? "nil") chars"
                       + " height=\(pair?.last.map { "\($0)" } ?? "nil")"
                       + (error.map { " error=\($0.localizedDescription)" } ?? ""))
                if error != nil { self?.renderedDocument = nil }   // let the next update retry
                guard let self, let height = pair?.last?.doubleValue, height > 0 else { return }
                // The body's own top padding, plus a little slack so a descender
                // on the last line is not the thing that gets cut off.
                self.onHeight?(CGFloat(height) + 32)
            }
        }

        /// Hands the questions to the page. Rebuilt whenever the document is,
        /// so switching concepts cannot leave the previous concept's test — and
        /// its half-typed answers — under the new entry.
        private func renderTest(into webView: WKWebView) {
            asked = pendingQuestions
            let payload = asked.map { q -> [String: Any] in
                ["prompt": q.prompt, "choices": q.choices, "correct": q.correct ?? -1]
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            // The returned length is the test as laid out, not as handed over:
            // "the call did not throw" and "there are questions on the page" are
            // different claims, and only the second one is the feature.
            webView.evaluateJavaScript(
                "window.renderTest(\(json)); document.getElementById('test').innerText.length"
            ) { value, error in
                weblog("test: \(self.asked.count) questions, "
                       + "\((value as? Int).map(String.init) ?? "nil") chars on the page"
                       + (error.map { " error=\($0.localizedDescription)" } ?? ""))
            }
        }

        // MARK: - Marking

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["action"] as? String == "submit",
                  let raw = body["answers"] as? [[String: Any]],
                  let webView else { return }
            let chosen = raw.map { ($0["choice"] as? Int) ?? -1 }
            let written = raw.map { ($0["text"] as? String) ?? "" }
            mark(chosen: chosen, written: written, in: webView)
        }

        /// Multiple choice is marked here, instantly. The written answers go to
        /// the model, which is the slow part — so the page is told the moment
        /// the choices are known and the written marks are filled in after.
        private func mark(chosen: [Int], written: [String], in webView: WKWebView) {
            let questions = asked
            // Which written questions were asked, and what was typed for them.
            let writtenIndices = questions.indices.filter { questions[$0].isWritten }
            let toGrade = writtenIndices.map {
                (question: questions[$0], answer: written[safe: $0] ?? "")
            }

            Task.detached { [coordinator = self] in
                // One call for every written answer, off the main thread.
                let graded = toGrade.isEmpty ? [] : Tutor.grade(toGrade)
                await MainActor.run {
                    var marks: [[String: Any]] = []
                    var total = 0.0
                    for (i, q) in questions.enumerated() {
                        var score = 0.0
                        var comment = ""
                        if q.isWritten {
                            // A grader that did not answer marks nothing rather
                            // than everything: a silent zero would reschedule
                            // the concept for tomorrow on the model's failure.
                            let slot = writtenIndices.firstIndex(of: i) ?? 0
                            if slot < graded.count {
                                score = graded[slot].score
                                comment = graded[slot].comment
                            } else {
                                score = 0.5
                                comment = "not marked — " + (Tutor.lastError ?? "no answer from the model")
                            }
                        } else {
                            score = (chosen[safe: i] ?? -1) == q.correct ? 1 : 0
                            comment = ""
                        }
                        total += score
                        marks.append(["score": score, "comment": comment,
                                      "chosen": chosen[safe: i] ?? -1,
                                      "scheme": q.expected])
                    }
                    let fraction = questions.isEmpty ? 0 : total / Double(questions.count)
                    coordinator.show(marks: marks, fraction: fraction,
                                     outOf: questions.count, in: webView)
                    coordinator.onScore?(fraction)
                }
            }
        }

        private func show(marks: [[String: Any]], fraction: Double,
                          outOf: Int, in webView: WKWebView) {
            let data = (try? JSONSerialization.data(withJSONObject: marks)) ?? Data("[]".utf8)
            let json = String(data: data, encoding: .utf8) ?? "[]"
            let summary = "\(Int((fraction * Double(outOf)).rounded())) out of \(outOf)"
                + " — \(Int((fraction * 100).rounded()))%"
            let summaryJSON = (try? JSONSerialization.data(withJSONObject: [summary]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            webView.evaluateJavaScript(
                "window.showMarks(\(json), \(summaryJSON)[0]); 1") { _, error in
                weblog("marks shown" + (error.map { " error=\($0.localizedDescription)" } ?? ""))
            }
        }
    }
}

private extension Array {
    /// Bounds-checked, because the answers come back from a web page and a
    /// short array should mark a question unanswered rather than crash the app.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
