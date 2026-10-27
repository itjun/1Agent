import AppKit
import Combine
import Foundation

/// App-wide work outlives the file page and the window that enqueued it.
@MainActor
final class FileTransferQueue: ObservableObject {
    static let shared = FileTransferQueue()
    static let storageKey = "files.transferQueue.v1"

    enum Phase: String, Codable {
        case queued, preparing, running, cancelling, completed, cancelled, failed, interrupted

        var isActive: Bool { [.queued, .preparing, .running, .cancelling].contains(self) }
        var canRetry: Bool { [.failed, .cancelled, .interrupted].contains(self) }
        var title: String {
            switch self {
            case .queued: String(localized: "Queued")
            case .preparing: String(localized: "Preparing…")
            case .running: String(localized: "Transferring…")
            case .cancelling: String(localized: "Cancelling…")
            case .completed: String(localized: "Completed")
            case .cancelled: String(localized: "Cancelled")
            case .failed: String(localized: "Failed")
            case .interrupted: String(localized: "Interrupted")
            }
        }
    }

    struct Job: Identifiable, Codable {
        let id: UUID
        let item: FileTransfer.Item
        let sourceHost: String?
        let targetHost: String?
        let directory: String
        let created: Date
        var phase: Phase
        var progress: Double = 0
        var error: String?
        var result: String?

        var name: String { (item.path as NSString).lastPathComponent }
        var sourceDescription: String { (sourceHost.map { $0 + ":" } ?? "") + item.path }
        var targetDescription: String { (targetHost.map { $0 + ":" } ?? "") + directory }
        var directionSymbol: String {
            if sourceHost == nil, targetHost != nil { return "arrow.up" }
            if sourceHost != nil, targetHost == nil { return "arrow.down" }
            return "arrow.right"
        }
        var directionTitle: String {
            if sourceHost == nil, targetHost != nil { return String(localized: "Upload") }
            if sourceHost != nil, targetHost == nil { return String(localized: "Download") }
            return String(localized: "Copy")
        }
    }

    private final class Request {
        weak var window: NSWindow?
        var choice: ConflictChoice?
        var prepare: Bool
        var toast: Int?
        var completion: ((Result<String, Error>) -> Void)?
        init(window: NSWindow?, choice: ConflictChoice? = nil, prepare: Bool = true,
             completion: ((Result<String, Error>) -> Void)? = nil) {
            self.window = window
            self.choice = choice
            self.prepare = prepare
            self.completion = completion
        }
    }

    @Published private(set) var jobs: [Job]
    private let defaults: UserDefaults
    private var requests: [UUID: Request] = [:]
    private var operation: (id: UUID, cancellation: FileOperationCancellation)?
    private var shuttingDown = false
    private var lastProgress = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        jobs = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Job].self, from: $0) } ?? []
        for index in jobs.indices where jobs[index].phase.isActive {
            jobs[index].phase = .interrupted
            jobs[index].progress = 0
        }
        persist()
    }

    var activeCount: Int { jobs.filter { $0.phase.isActive }.count }
    var hasActiveTransfers: Bool { activeCount > 0 }

    @discardableResult
    func enqueue(_ items: [FileTransfer.Item], from source: any FileSystem, to target: any FileSystem,
                 into directory: String, window: NSWindow?) -> [UUID] {
        guard !shuttingDown, !directory.isEmpty else { return [] }
        let ids = items.map { add($0, sourceHost: source.host, targetHost: target.host,
                                  directory: directory, request: Request(window: window)) }
        persist()
        pump()
        return ids
    }

    /// Used by terminal drops and Quick Look. Waiting callers do not own the job's lifecycle.
    func transfer(_ items: [FileTransfer.Item], from source: any FileSystem, to target: any FileSystem,
                  into directory: String, window: NSWindow?, choice: ConflictChoice? = nil,
                  prepare: Bool = true) async throws -> [String] {
        var paths: [String] = []
        for item in items {
            let path: String = try await withCheckedThrowingContinuation { continuation in
                guard !shuttingDown else { continuation.resume(throwing: CancellationError()); return }
                _ = add(item, sourceHost: source.host, targetHost: target.host, directory: directory,
                        request: Request(window: window, choice: choice, prepare: prepare,
                                         completion: { continuation.resume(with: $0) }))
                persist()
                pump()
            }
            paths.append(path)
        }
        return paths
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].phase.isActive else { return }
        if operation?.id == id {
            jobs[index].phase = .cancelling
            operation?.cancellation.cancel()
        } else {
            jobs[index].phase = .cancelled
            requests.removeValue(forKey: id)?.completion?(.failure(CancellationError()))
        }
        persist()
    }

    func retry(_ id: UUID, window: NSWindow? = nil) {
        guard !shuttingDown, let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].phase.canRetry else { return }
        jobs[index].phase = .queued
        jobs[index].progress = 0
        jobs[index].error = nil
        jobs[index].result = nil
        // Original paths are retained. Conflict and encoding decisions are made again.
        requests[id] = Request(window: window)
        persist()
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.phase == .completed || $0.phase == .cancelled }
        persist()
    }

    /// Persist first: abrupt process exit must never resurrect queued work automatically.
    func interruptForTermination() {
        shuttingDown = true
        for index in jobs.indices where jobs[index].phase.isActive { jobs[index].phase = .interrupted }
        persist()
        operation?.cancellation.cancel()
    }

    private func add(_ item: FileTransfer.Item, sourceHost: String?, targetHost: String?, directory: String,
                     request: Request) -> UUID {
        let id = UUID()
        jobs.append(Job(id: id, item: item, sourceHost: sourceHost, targetHost: targetHost,
                        directory: directory, created: Date(), phase: .queued))
        requests[id] = request
        return id
    }

    private func pump() {
        guard !shuttingDown, operation == nil, let job = jobs.first(where: { $0.phase == .queued }) else { return }
        let cancellation = FileOperationCancellation()
        operation = (job.id, cancellation)
        let request = requests[job.id] ?? Request(window: nil)
        update(job.id) { $0.phase = .preparing }
        Task { [self] in
            let result: Result<String, Error>
            do {
                let path = try await FileOperationContext.$cancellation.withValue(cancellation) {
                    let source = fileSystem(for: job.sourceHost), target = fileSystem(for: job.targetHost)
                    try cancellation.check()
                    let prepared: UploadCheck.Prepared?
                    if request.prepare {
                        prepared = try await UploadCheck.prepare([job.item], from: source, to: target, window: request.window)
                        guard prepared != nil else { throw CancellationError() }
                    } else { prepared = nil }
                    defer { prepared?.cleanUp() }
                    try cancellation.check()
                    let items = prepared?.items ?? [job.item]
                    let choice: ConflictChoice
                    if let selected = request.choice { choice = selected }
                    else {
                        let existing = try await FileTransfer.conflicts(items, from: source, to: target, into: job.directory)
                        guard let selected = await FileTransfer.askAboutConflicts(existing, in: request.window) else {
                            throw CancellationError()
                        }
                        choice = selected
                    }
                    try cancellation.check()
                    update(job.id) { $0.phase = .running }
                    request.toast = TransferToast.shared.begin(job.name, in: request.window)
                    let paths = try await FileTransfer.copy(items, from: source, to: target,
                                                           into: job.directory, choice: choice) { [weak self] fraction in
                        Task { @MainActor in self?.report(job.id, fraction: fraction) }
                    }
                    guard let path = paths.first else { throw FileError.message(String(localized: "Could not create the file")) }
                    return path
                }
                result = .success(path)
            } catch { result = .failure(error) }
            if !shuttingDown {
                update(job.id) {
                    switch result {
                    case .success(let path): $0.phase = .completed; $0.progress = 1; $0.result = path
                    case .failure(let error):
                        $0.phase = cancellation.isCancelled || error is CancellationError ? .cancelled : .failed
                        $0.error = $0.phase == .failed ? error.localizedDescription : nil
                    }
                }
            }
            if !shuttingDown {
                switch result {
                case .success:
                    if let toast = request.toast { TransferToast.shared.finish(toast, String(localized: "Completed")) }
                case .failure(let error):
                    if cancellation.isCancelled || error is CancellationError {
                        if let toast = request.toast { TransferToast.shared.finish(toast, String(localized: "Cancelled")) }
                    } else { TransferToast.shared.fail(request.toast, error.localizedDescription, in: request.window) }
                }
            }
            FileBrowserStore.shared.refresh(host: job.targetHost)
            requests.removeValue(forKey: job.id)?.completion?(result)
            operation = nil
            pump()
        }
    }

    private func report(_ id: UUID, fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].phase == .running else { return }
        let now = Date()
        guard now.timeIntervalSince(lastProgress) >= 0.1 || fraction >= 1 else { return }
        lastProgress = now
        jobs[index].progress = min(1, max(0, fraction))
        if let toast = requests[id]?.toast {
            TransferToast.shared.progress(toast, jobs[index].name + " · " + String(Int(fraction * 100)) + "%", fraction: fraction)
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) { defaults.set(data, forKey: Self.storageKey) }
    }
}
