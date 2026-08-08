import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { VoiceStore.shared.bootstrap() }
    }
}

@main
enum Main {
    /// Held strongly: NSApplication.delegate is a weak reference.
    private static var delegate: AppDelegate?

    static func main() {
        // With no menu bar item there's no place to click, so the few things that
        // would have been menu commands are flags instead.
        let args = CommandLine.arguments
        if args.contains("--enable-login-item") {
            do { try SMAppService.mainApp.register(); print("Login item enabled.") }
            catch { print("Failed: \(error.localizedDescription)"); exit(1) }
            exit(0)
        }
        if args.contains("--disable-login-item") {
            do { try SMAppService.mainApp.unregister(); print("Login item disabled.") }
            catch { print("Failed: \(error.localizedDescription)"); exit(1) }
            exit(0)
        }
        if args.contains("--selftest") { selfTest() }
        // Run a .wav straight through the real pipeline — vocabulary priming and
        // replacement rules included — so vocabulary edits can be checked without
        // having to say anything.
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            Config.bootstrap()
            do {
                let text = try Transcriber.transcribe(URL(fileURLWithPath: args[i + 1]))
                print(text)
                exit(0)
            } catch let e as VBError {
                print("error: \(e.text)"); exit(1)
            } catch {
                print("error: \(error.localizedDescription)"); exit(1)
            }
        }
        if let i = args.firstIndex(of: "--target"), i + 1 < args.count {
            guard let t = DeliveryTarget(rawValue: args[i + 1]) else {
                print("unknown target '\(args[i + 1])' — expected: \(DeliveryTarget.allCases.map(\.rawValue).joined(separator: ", "))")
                exit(1)
            }
            Prefs.target = t
            print("delivery target set to '\(t.rawValue)'")
            exit(0)
        }
        if args.contains("--status") {
            Config.bootstrap()
            let tokens = Config.approximateTokenCount(Config.vocabularyPrompt())
            let overLimit = tokens > Config.promptTokenLimit
            print("delivery target:       \(Prefs.target.rawValue)")
            print("press return for me:   \(Prefs.autoSubmit)")
            print("vocabulary:            ~\(tokens) tokens of \(Config.promptTokenLimit)"
                  + (overLimit ? "  ⚠️ OVER — trailing terms are being dropped" : ""))
            print("replacement rules:     \(Config.replacements().count)")
            // Read what the GUI app reported. Checking AXIsProcessTrusted() here
            // measures the terminal, not VoiceBridge, and always said false.
            if let r = Runtime.lastReport() {
                let fresh = r.age < 900
                print("accessibility trusted: \(r.trusted)"
                      + (fresh ? "" : "   (last reported \(Int(r.age / 60))m ago — relaunch to refresh)"))
                print("hotkey monitor:        \(r.monitor ? "running" : "NOT running")")
            } else {
                print("accessibility trusted: unknown — launch the app once so it can report")
            }
            print("login item status:     \(SMAppService.mainApp.status.rawValue)")
            print("model:                 \(Config.modelURL.path)")
            print("whisper-cli:           \(Config.whisperCLI?.path ?? "NOT FOUND")")
            exit(0)
        }

        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        // .accessory: no Dock tile, no app switcher entry, no menu bar item.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Exercises the double-tap state machine directly — the one piece of new logic
    /// that can't be verified by pressing keys from a script.
    private static func selfTest() -> Never {
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }
        let t = Date(timeIntervalSince1970: 1_000_000)
        let ctrl = NSEvent.ModifierFlags.control
        let none = NSEvent.ModifierFlags()
        func at(_ s: Double) -> Date { t.addingTimeInterval(s) }

        var m = DoubleTapMonitor(flag: .control)
        m.process(flags: ctrl, at: at(0))
        m.process(flags: none, at: at(0.05))
        check("quick double tap fires", m.process(flags: ctrl, at: at(0.20)))

        m = DoubleTapMonitor(flag: .control)
        m.process(flags: ctrl, at: at(0))
        m.process(flags: none, at: at(0.05))
        check("slow double tap ignored", !m.process(flags: ctrl, at: at(1.0)))

        // Typing ⌃C must never be mistaken for a tap.
        m = DoubleTapMonitor(flag: .control)
        m.process(flags: ctrl, at: at(0))
        m.noteKeyPress()
        m.process(flags: none, at: at(0.05))
        check("chord then tap ignored", !m.process(flags: ctrl, at: at(0.20)))

        m = DoubleTapMonitor(flag: .control)
        m.process(flags: [ctrl, .command], at: at(0))
        m.process(flags: .command, at: at(0.05))
        check("control+command ignored", !m.process(flags: [ctrl, .command], at: at(0.20)))

        m = DoubleTapMonitor(flag: .control)
        var fired = 0
        for i in 0..<3 {
            if m.process(flags: ctrl, at: at(Double(i) * 0.15)) { fired += 1 }
            m.process(flags: none, at: at(Double(i) * 0.15 + 0.05))
        }
        check("triple tap fires once", fired == 1, "fired \(fired)x")

        // Held down without release is not two taps.
        m = DoubleTapMonitor(flag: .control)
        m.process(flags: ctrl, at: at(0))
        check("held modifier does not repeat", !m.process(flags: ctrl, at: at(0.2)))

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
