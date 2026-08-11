import Foundation

/// Syllabi from courses that already solved this problem.
///
/// The point is not to follow any one of them. Each is shaped by its own
/// department: CS149 and 15-418 teach parallel hardware to people who will write
/// CUDA, 6.5940 teaches efficiency to people shrinking models, CS336 teaches
/// building an LM end to end, and the ML-systems courses sit between. What this
/// reader needs is the union, ordered by dependency rather than by semester —
/// which is exactly what a graph can express and a syllabus cannot.
///
/// Fetched rather than hard-coded so the curriculum can be refreshed when the
/// courses are, and so the source of every claim about "what a course covers" is
/// a page you can open.
enum Courses {
    struct Course {
        var name: String
        var url: String
    }

    static let all: [Course] = [
        .init(name: "MIT 6.5940 — TinyML and Efficient Deep Learning Computing",
              url: "https://hanlab.mit.edu/courses/2024-fall-65940"),
        .init(name: "Stanford CS149 — Parallel Computing",
              url: "https://gfxcourses.stanford.edu/cs149/fall24"),
        .init(name: "CMU 15-418/618 — Parallel Computer Architecture and Programming",
              url: "https://www.cs.cmu.edu/~418/schedule.html"),
        .init(name: "CMU 10-414/714 — Deep Learning Systems",
              url: "https://dlsyscourse.org/lectures/"),
        .init(name: "Stanford CS336 — Language Modeling from Scratch",
              url: "https://stanford-cs336.github.io/spring2025/"),
        .init(name: "CMU 15-442/642 — Machine Learning Systems",
              url: "https://mlsyscourse.org/"),
    ]

    /// The readable text of a syllabus page, trimmed to the lines that look like
    /// topics. Crude on purpose: the model reads this, and a lecture list
    /// surrounded by navigation chrome is still a lecture list.
    static func topics(of course: Course) -> [String] {
        guard let url = URL(string: course.url) else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("Mozilla/5.0 (Macintosh) Frontier/1.0", forHTTPHeaderField: "User-Agent")

        let done = DispatchSemaphore(value: 0)
        var body: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data.flatMap { String(data: $0, encoding: .utf8) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 45) == .success, var text = body else { return [] }

        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        var seen: Set<String> = []
        return text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 && $0.count < 120 && seen.insert($0).inserted }
    }
}
