import AppKit
import SwiftUI
import WebKit

/// Recent downloads: Window ▸ Downloads (⌥⌘L) and the arrow at a space's sidebar foot. docs/spaces.md
/// § Browsing.
///
/// - Every download a card starts, with progress while it runs; the newest 30 kept between launches
///   (`PMRecentDownloads`).
/// - Click opens the file, the magnifier shows it in Finder, a row drags out as the file. A file that's
///   gone since says so.
/// - Clear forgets finished ones; the files stay.
@MainActor
@Observable
final class CanvasDownloads {
    static let shared = CanvasDownloads()

    struct Item: Identifiable, Equatable, Codable {
        enum State: String, Codable { case running, done, failed }
        var id = UUID()
        var name: String
        var path: String?
        var host: String?
        var started = Date()
        var state: State = .running
        var fraction: Double = 0
        var bytes: Int64 = 0
        var file: URL? { path.map { URL(fileURLWithPath: $0) } }
    }

    private(set) var items: [Item] = []
    /// Bumped when one finishes, so the sidebar's arrow can say so.
    private(set) var finishedCount = 0
    @ObservationIgnored private var progressWatch: [UUID: NSKeyValueObservation] = [:]
    private static let defaultsKey = "PMRecentDownloads"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let read = try? JSONDecoder().decode([Item].self, from: data) {
            items = read.map { var item = $0; if item.state == .running { item.state = .failed }; return item }
        }
    }

    var running: Bool { items.contains { $0.state == .running } }

    func started(_ download: WKDownload, name: String, at file: URL) -> UUID {
        let item = Item(name: name, path: file.path, host: download.originalRequest?.url?.host())
        items.insert(item, at: 0)
        let id = item.id
        progressWatch[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted, bytes = progress.completedUnitCount
            DispatchQueue.main.async { self?.update(id) { $0.fraction = fraction; $0.bytes = bytes } }
        }
        save()
        return id
    }

    func finished(_ id: UUID, ok: Bool) {
        progressWatch[id] = nil
        update(id) {
            $0.state = ok ? .done : .failed
            if ok {
                $0.fraction = 1
                if let path = $0.path,
                   let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 { $0.bytes = size }
            }
        }
        if ok { finishedCount += 1 }
        save()
    }

    func clear() {
        items.removeAll { $0.state != .running }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id && $0.state != .running }
        save()
    }

    private func update(_ id: UUID, _ edit: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
    }

    private func save() {
        let kept = Array(items.prefix(30))
        if let data = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

// MARK: - The list

struct CanvasDownloadsList: View {
    var downloads = CanvasDownloads.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clear() }
                    .controlSize(.small)
                    .disabled(!downloads.items.contains { $0.state != .running })
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if downloads.items.isEmpty {
                Text("No downloads").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 320)
    }
}

private struct DownloadRow: View {
    let item: CanvasDownloads.Item
    @State private var hover = false

    private var exists: Bool { item.path.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.path.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSImage())
                .resizable().frame(width: 30, height: 30)
                .opacity(exists || item.state == .running ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                if item.state == .running {
                    ProgressView(value: item.fraction).controlSize(.small)
                } else {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.state == .done, exists {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.file!]) } label: {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.primary.opacity(hover ? 0.06 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if item.state == .done, exists, let file = item.file { NSWorkspace.shared.open(file) } }
        .onDrag { (item.state == .done ? item.file.flatMap { NSItemProvider(contentsOf: $0) } : nil) ?? NSItemProvider() }
        .contextMenu {
            if item.state == .done, exists, let file = item.file {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Divider()
            }
            Button("Remove from List") { CanvasDownloads.shared.remove(item.id) }.disabled(item.state == .running)
        }
        .help(item.path ?? item.name)
    }

    private var detail: String {
        switch item.state {
        case .failed: return "Failed"
        case .running: return ""
        case .done:
            guard exists else { return "Moved or deleted" }
            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            return [size, item.host].compactMap { $0 }.joined(separator: " — ")
        }
    }
}

/// Window ▸ Downloads (⌥⌘L).
@MainActor
final class CanvasDownloadsWindow: NSObject, NSWindowDelegate {
    static let shared = CanvasDownloadsWindow()
    private var window: NSWindow?

    @objc func show(_ sender: Any?) {
        if let window { return window.makeKeyAndOrderFront(nil) }
        let made = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                           styleMask: [.titled, .closable, .resizable, .utilityWindow],
                           backing: .buffered, defer: false)
        made.title = "Downloads"
        made.isReleasedWhenClosed = false
        made.hidesOnDeactivate = false
        made.contentView = NSHostingView(rootView: CanvasDownloadsList())
        made.setFrameAutosaveName("PMDownloadsWindow")
        made.delegate = self
        if made.frame.origin == .zero { made.center() }
        window = made
        made.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
