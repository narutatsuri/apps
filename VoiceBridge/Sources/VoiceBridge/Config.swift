import Foundation

struct VBError: Error { let text: String
    static func message(_ s: String) -> VBError { VBError(text: s) }
}

/// Everything tunable lives in plain files under ~/.config/voicebridge so the
/// vocabulary and fix-ups can be edited without rebuilding the app.
enum Config {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voicebridge")
    static var vocabularyURL: URL { dir.appendingPathComponent("vocabulary.txt") }
    static var replacementsURL: URL { dir.appendingPathComponent("replacements.txt") }

    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceBridge")
    static var modelURL: URL { support.appendingPathComponent("ggml-small.en.bin") }

    static var whisperCLI: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Defaults written on first launch

    private static let defaultVocabulary = """
    # Words fed to whisper as context before it transcribes. Proper nouns and jargon
    # it would otherwise guess at belong here. This is the layer that turns
    # "dellaplee" into "della-pli" and "Quinn" into "Qwen".
    #
    # ONLY LIST WORDS WHISPER GETS WRONG. Ordinary English it already handles —
    # "checkpoint", "dataset", "attention", "benchmark" — costs budget and buys
    # nothing. whisper truncates the prompt near 224 tokens and drops the overflow
    # silently, so a bloated list quietly stops working.
    #
    # Check your budget:  VoiceBridge --status
    # For one-off stragglers use replacements.txt, which has no length limit.
    #
    # Re-read on every transcription — no rebuild, no restart.

    Cluster: della-pli, della, SLURM, sbatch, srun, squeue, scancel, sacct, salloc,
    A100, H100.

    Tools: tmux, conda, venv, uv, rsync, scp, JSONL, YAML, TOML, stdout, stderr,
    Codex.

    Models: Olmo, Qwen, Llama, Mistral, Mixtral, Gemma, DeepSeek, Phi, Falcon,
    Pythia, BERT, RoBERTa, DeBERTa, T5, CLIP.

    ML: PyTorch, CUDA, HuggingFace, safetensors, vLLM, LoRA, QLoRA, RLHF, DPO, PPO,
    tokenizer, embeddings, perplexity, logits, softmax, ablation, pretraining,
    hyperparameter, anisotropy.
    """

    private static let defaultReplacements = """
    # Literal fix-ups applied after transcription, one per line: wrong => right
    # Case-insensitive, whole-word. For whatever the vocabulary prompt still misses.
    spatch => sbatch
    s batch => sbatch
    es batch => sbatch
    squeue up => squeue
    tea mux => tmux
    t mux => tmux
    TX => tmux
    della plea => della-pli
    della ply => della-pli
    della p l i => della-pli

    # Model names — errors actually observed from whisper, kept as a safety net
    # for when the audio is noisy or the vocabulary prompt gets crowded out.
    Quinn => Qwen
    quen => Qwen
    kwen => Qwen
    Gwen => Qwen
    allmo => Olmo
    all mo => Olmo
    Elmo => Olmo
    mistrial => Mistral
    lama => Llama
    hugging face => HuggingFace
    pie torch => PyTorch
    pi torch => PyTorch
    """

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: vocabularyURL.path) {
            try? defaultVocabulary.write(to: vocabularyURL, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: replacementsURL.path) {
            try? defaultReplacements.write(to: replacementsURL, atomically: true, encoding: .utf8)
        }
    }

    /// Comment lines are stripped; the rest is collapsed into one priming string.
    static func vocabularyPrompt() -> String {
        let raw = (try? String(contentsOf: vocabularyURL, encoding: .utf8)) ?? defaultVocabulary
        let body = raw.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: " ")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// whisper truncates the initial prompt near 224 tokens and drops the overflow
    /// silently, so an oversized vocabulary quietly stops working. This is a rough
    /// estimate — whisper uses a GPT-2-style BPE, and ~3.5 characters per token errs
    /// slightly high for technical jargon, which is the safe direction.
    static let promptTokenLimit = 224

    static func approximateTokenCount(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 3.5).rounded()))
    }

    static func replacements() -> [(String, String)] {
        let raw = (try? String(contentsOf: replacementsURL, encoding: .utf8)) ?? defaultReplacements
        return raw.split(separator: "\n").compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#"), s.contains("=>") else { return nil }
            let parts = s.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            return from.isEmpty ? nil : (from, to)
        }
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    /// Off by default: you see the text in the prompt and press Return yourself.
    static var autoSubmit: Bool {
        get { d.bool(forKey: "autoSubmit") }
        set { d.set(newValue, forKey: "autoSubmit") }
    }

    /// Where the transcript goes. Defaults to wherever the cursor is.
    static var target: DeliveryTarget {
        get { DeliveryTarget(rawValue: d.string(forKey: "target") ?? "") ?? .focused }
        set { d.set(newValue.rawValue, forKey: "target") }
    }
}
