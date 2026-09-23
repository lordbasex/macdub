import Foundation
import SwiftUI
import Translation

/// Bridges the pipeline to Apple's `Translation` framework.
///
/// `TranslationSession` is only obtainable through the SwiftUI `.translationTask` modifier and
/// is valid only while that modifier's closure is running. So `TranslationHostView` (an invisible
/// view in the main window) calls `run(session:)` and keeps it alive as a job loop; the rest of
/// the app just calls `translate(_:)`.
@MainActor
final class TranslationBridge: ObservableObject {
    enum Status: Equatable {
        case idle
        case preparing
        case ready
        case unavailable(String)
    }

    /// Bound by `TranslationHostView`. Changing it restarts the session.
    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var status: Status = .idle

    private struct Job {
        let text: String
        let completion: (Result<String, Error>) -> Void
    }

    private var pending: [Job] = []
    private var waiter: CheckedContinuation<Job?, Never>?
    private let maxPending = 32

    // MARK: Public API

    func configure(source: Locale.Language, target: Locale.Language) {
        if let c = configuration, c.source == source, c.target == target {
            return
        }
        status = .idle
        configuration = TranslationSession.Configuration(source: source, target: target)
    }

    /// Ask the session to (re)prepare; shows the model download sheet if needed.
    func prepare() {
        if configuration == nil { return }
        status = .idle
        configuration?.invalidate()
    }

    func translate(_ text: String) async throws -> String {
        if case .unavailable(let msg) = status { throw MacDubError.translationFailed(msg) }
        return try await withCheckedThrowingContinuation { cont in
            enqueue(Job(text: text) { cont.resume(with: $0) })
        }
    }

    func cancelPending() {
        let jobs = pending
        pending.removeAll()
        for job in jobs { job.completion(.failure(CancellationError())) }
    }

    // MARK: Session loop (called by TranslationHostView)

    func run(session: TranslationSession) async {
        Log.translation.info("Translation session started")
        status = .preparing
        do {
            try await session.prepareTranslation()
            status = .ready
            Log.translation.info("Translation model ready")
        } catch {
            Log.translation.error("prepareTranslation failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable(error.localizedDescription)
            cancelPending()
            return
        }

        while !Task.isCancelled, let job = await nextJob() {
            do {
                let response = try await session.translate(job.text)
                job.completion(.success(response.targetText))
            } catch {
                Log.translation.error("translate failed: \(error.localizedDescription, privacy: .public)")
                job.completion(.failure(MacDubError.translationFailed(error.localizedDescription)))
            }
        }
        Log.translation.info("Translation session ended")
        if status == .ready { status = .idle }
    }

    // MARK: Queue

    private func enqueue(_ job: Job) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: job)
            return
        }
        pending.append(job)
        if pending.count > maxPending {
            // Way behind: drop the oldest so the dub keeps up with the video.
            let dropped = pending.removeFirst()
            dropped.completion(.failure(CancellationError()))
        }
    }

    private func nextJob() async -> Job? {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Job?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                } else {
                    waiter = cont
                }
            }
        } onCancel: {
            Task { @MainActor in
                let w = self.waiter
                self.waiter = nil
                w?.resume(returning: nil)
            }
        }
    }
}

/// Invisible view that owns the `TranslationSession`. Put it anywhere in the main window.
struct TranslationHostView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(bridge.configuration) { session in
                await bridge.run(session: session)
            }
    }
}

// MARK: - Language catalogue helpers

enum TranslationCatalog {
    /// Languages the Translation framework can produce, sorted by display name.
    static func supportedTargetLanguages() async -> [Locale.Language] {
        let langs = await LanguageAvailability().supportedLanguages
        return langs.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    /// "español (es)", "español (México) (es-MX)". The minimal identifier: the maximal one
    /// spells out the inferred script and region ("español (latino, España)").
    static func displayName(_ language: Locale.Language) -> String {
        let id = language.minimalIdentifier
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return "\(name) (\(language.minimalIdentifier))"
    }
}
