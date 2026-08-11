import AppKit

/// FRONTIER_CLICKTEST=1 — replays "clicking through the sidebar" for real.
///
/// Selecting a row does exactly one thing: it writes `model.selected` through
/// the List binding. This walks a scripted sequence of selections on the live
/// app — written and unwritten concepts, imported and original, back and forth
/// across the branch that tears the web view down — announcing each step on
/// stdout so an external screenshotter can catch the window in every state.
@MainActor
enum ClickDiagnose {
    static func scheduleIfAsked(model: Model) {
        guard ProcessInfo.processInfo.environment["FRONTIER_CLICKTEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { run(model) }
        }
    }

    private static func run(_ model: Model) {
        var steps = ["gpu-execution-model"]                       // written
        if let book = model.concepts.first(where: {
            $0.courses.contains { $0.hasPrefix("RLHF Book") } }) {
            steps.append(book.id)                                 // imported, unwritten
        }
        steps.append("gpu-execution-model")                       // back to written
        if let survey = model.concepts.first(where: {
            $0.courses.contains { $0.hasPrefix("Beyond PPO") } }) {
            steps.append(survey.id)
        }
        if let ready = model.ready.first(where: { $0.id != "gpu-execution-model" }) {
            steps.append(ready.id)
        }
        steps.append("gpu-execution-model")

        var i = 0
        func step() {
            guard i < steps.count else { NSLog("CLICKTEST done"); return }
            let id = steps[i]
            i += 1
            model.selected = id
            NSLog("CLICKTEST selected %@", id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { step() }
        }
        step()
    }
}
