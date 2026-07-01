import Foundation

/// Shared read/write of `~/.config/pm/task-timing.json` (`{task_key, seen_at}`) — the record of when
/// the current focused task was first seen. Drives the menubar's stale tint and the stale-task
/// notifications, and shares its schema with the Raycast extension's `task-timing`.
struct TaskTiming: Codable {
    let taskKey: String
    let seenAt: Double

    enum CodingKeys: String, CodingKey {
        case taskKey = "task_key"
        case seenAt = "seen_at"
    }

    private static var url: URL { PMFiles.configDir.appendingPathComponent("task-timing.json") }

    static func load() -> TaskTiming? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaskTiming.self, from: data)
    }

    static func save(taskKey: String, seenAt: Double) {
        guard let data = try? JSONEncoder().encode(TaskTiming(taskKey: taskKey, seenAt: seenAt)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
