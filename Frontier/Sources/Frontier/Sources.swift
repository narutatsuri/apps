import Foundation

/// Checking that a citation points at something.
///
/// The app's whole claim is that assertions are checkable, and a URL that 404s
/// quietly breaks that — worse than an uncited claim, because it looks sourced.
/// A HEAD request is enough to tell the difference and costs nothing.
enum SourceCheck {
    static func reachable(_ url: String) -> Bool? {
        guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true else { return false }
        var request = URLRequest(url: u, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue("Frontier/1.0 (personal study app)", forHTTPHeaderField: "User-Agent")

        let done = DispatchSemaphore(value: 0)
        var code: Int?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 25) == .success else { return nil }
        guard let code else { return nil }
        // 405 means the server dislikes HEAD, not that the page is missing.
        return (200..<400).contains(code) || code == 405
    }
}
