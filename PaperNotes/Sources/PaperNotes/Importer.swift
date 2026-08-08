import Foundation

/// Headless ingest: `--import <pdf|directory>…`
///
/// Same pipeline as the Finder route, minus opening the PDF for reading — so a pile
/// can be catalogued without seven Preview windows appearing. Imported papers carry
/// no note, so they show as "catalogued only" until you actually read them.
enum Importer {
    /// `--refresh` — re-fetch metadata for papers already in the library, without
    /// touching their notes. Needed whenever a new metadata field is added, since
    /// import deliberately skips anything already present.
    static func refresh() -> Never {
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let papers = MainActor.assumeIsolated { Library.shared.papers }
        var updated = 0
        for var paper in papers {
            let done = DispatchSemaphore(value: 0)
            var fetched: Metadata.Result?
            let id = paper.arxivID
            Task.detached {
                fetched = await Metadata.fetch(arxivID: id)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 60)
            guard let m = fetched else {
                print("  ? \(paper.arxivID) — lookup failed")
                continue
            }
            paper.title = m.title
            paper.authors = m.authors
            paper.year = m.year
            paper.venue = m.venue
            paper.citations = m.citations
            MainActor.assumeIsolated { Library.shared.save(paper) }
            updated += 1
            print(String(format: "  ✓ %-12s %5d citations  %@",
                         (paper.arxivID as NSString).utf8String!, m.citations,
                         String(m.title.prefix(46))))
            Thread.sleep(forTimeInterval: 0.35)
        }
        print("\nrefreshed \(updated) of \(papers.count)")
        exit(0)
    }

    /// `--adopt-pdfs` — copy every referenced PDF into the app's own store and
    /// rewrite the paths, so the originals can be deleted safely.
    static func adoptPDFs() -> Never {
        MainActor.assumeIsolated { Library.shared.bootstrap() }
        let papers = MainActor.assumeIsolated { Library.shared.papers }
        var adopted = 0, already = 0, failed: [String] = []
        for var paper in papers {
            guard !paper.pdfPath.isEmpty else { continue }
            let source = URL(fileURLWithPath: paper.pdfPath)
            if source.deletingLastPathComponent().standardizedFileURL
                == Library.pdfStore.standardizedFileURL { already += 1; continue }
            guard let newPath = Library.adopt(source, for: paper.arxivID) else {
                failed.append("\(paper.arxivID)  \(source.lastPathComponent)")
                continue
            }
            paper.pdfPath = newPath
            MainActor.assumeIsolated { Library.shared.save(paper) }
            adopted += 1
        }
        print("adopted \(adopted), already in store \(already), failed \(failed.count)")
        for f in failed { print("  FAILED  \(f)") }
        if failed.isEmpty {
            print("\nEvery PDF is now in \(Library.pdfStore.path).")
            print("The originals are no longer referenced and can be deleted.")
        } else {
            print("\nDo NOT delete the originals — the failures above are still only there.")
        }
        exit(failed.isEmpty ? 0 : 1)
    }

    static func run(_ arguments: [String]) -> Never {
        var pdfs: [URL] = []
        for path in arguments {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                print("  skip (not found): \(path)")
                continue
            }
            if isDir.boolValue {
                // Recursive: a real library is organised into folders, and a
                // single-level scan found nothing at all in ~/Papers.
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "pdf" { pdfs.append(item) }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                pdfs.append(url)
            }
        }
        guard !pdfs.isEmpty else { print("No PDFs found."); exit(1) }

        // Safe: this runs on the main thread before NSApplication.run.
        MainActor.assumeIsolated { Library.shared.bootstrap() }

        var added = 0, skipped = 0, totalRefs = 0
        for url in pdfs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Filename first, then the arXiv banner inside the PDF. Libraries are
            // named for humans, not for identifiers.
            var resolved = PDFRefs.idFromFilename(url.lastPathComponent) ?? PDFRefs.ownID(in: url)
            if resolved == nil {
                // Third try: search by title. Some publishers strip the arXiv banner.
                let guess = PDFRefs.guessTitle(in: url)
                    ?? url.deletingPathExtension().lastPathComponent
                let waiter = DispatchSemaphore(value: 0)
                var found: String?
                Task.detached { found = await Metadata.arxivID(forTitle: guess); waiter.signal() }
                _ = waiter.wait(timeout: .now() + 60)
                resolved = found
                if found != nil { print("  (resolved by title search)") }
            }
            guard let id = resolved else {
                print("  skip (no arXiv id in filename, page 1, or by title): \(url.lastPathComponent)")
                skipped += 1
                continue
            }
            if MainActor.assumeIsolated({ Library.shared.paper(withID: id) }) != nil {
                print("  already present: \(id)")
                skipped += 1
                continue
            }

            var paper = Paper(arxivID: id)
            paper.refs = PDFRefs.references(in: url, excluding: id)
            paper.title = PDFRefs.guessTitle(in: url) ?? ""
            paper.pdfPath = Library.adopt(url, for: id) ?? url.path
            paper.readOn = Date()
            // The containing folder is a topic label you already curated by hand;
            // keeping it costs nothing and it is better than any tag I could infer.
            let folder = url.deletingLastPathComponent().lastPathComponent
            if !folder.isEmpty, folder != "Papers", folder != "Downloads" {
                paper.tags = [folder]
            }

            // Detached so the semaphore isn't waiting on the thread doing the work.
            let done = DispatchSemaphore(value: 0)
            var fetched: Metadata.Result?
            Task.detached {
                fetched = await Metadata.fetch(arxivID: id)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 60)
            if let m = fetched {
                paper.title = m.title
                paper.authors = m.authors
                paper.year = m.year
                paper.venue = m.venue
                paper.citations = m.citations
            }

            MainActor.assumeIsolated { Library.shared.save(paper) }
            added += 1
            totalRefs += paper.refs.count
            print(String(format: "  + %-12s %3d refs  %@", (id as NSString).utf8String!,
                         paper.refs.count, String(paper.title.prefix(52))))
            // Courtesy to OpenAlex, which asks for a modest request rate.
            Thread.sleep(forTimeInterval: 0.35)
        }

        let library = MainActor.assumeIsolated { Library.shared.papers }
        let edges = Relations.edges(in: library)
        print("""

        imported \(added), skipped \(skipped), \(totalRefs) references extracted
        library now \(library.count) papers, \(edges.count) connections
        """)
        // A batch import deliberately does not appraise inline: that is one claude
        // call per paper, and a 60-paper import would sit there for the better part
        // of an hour with no way to stop it.
        let ungraded = library.filter { $0.appraisal == .unset && !$0.pdfPath.isEmpty }.count
        if ungraded > 0 {
            print("\n\(ungraded) papers have no appraisal yet — run --appraise to grade them.")
        }
        exit(0)
    }
}
