import SwiftUI
import PmLib

/// The Waiting window: one column, one section per thing being waited on.
///
/// The inline token on a task line answers "why can't I do this?" — it sits in the sentence and wraps
/// with it. This answers the other question, "what am I waiting on?", and the shape follows: the
/// target is a heading, the tasks are its list, and every row under a heading lines up. That alignment
/// is what was given up by drawing the wait inline, and this is where it's paid back.
///
/// Released groups sit at the top with their own colour and a button that clears the whole group —
/// see `waitingGroups` for why that band goes first. Everything else is the same list in the order it
/// will still be in tomorrow.
struct WaitingView: View {
    @StateObject private var model = WaitingModel()
    /// Whether a project name keeps its code — app-wide, see `ProjectCodes`. Bound so the list
    /// re-labels itself the moment it's toggled.
    @AppStorage(ProjectCodes.defaultsKey) private var showsCode = true

    var body: some View {
        VStack(spacing: 0) {
            if let failure = model.failure { banner(failure) }
            content
            Divider()
            footer
        }
        .frame(minWidth: 380, minHeight: 260)
        .onAppear { model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(model.buckets.enumerated()), id: \.offset) { _, bucket in
                        section(bucket)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: One target

    @ViewBuilder
    private func section(_ bucket: WaitingBucket) -> some View {
        let released = bucket.state == "released"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol(bucket))
                    .foregroundStyle(released ? Color.green : .secondary)
                    .font(.caption)
                // A resolved target is a place to go, so it's a button; an unresolved one is a name,
                // and dressing a name as a link would promise navigation PM can't perform.
                if bucket.folder != nil {
                    Button(bucket.title) { model.open(bucket) }
                        .buttonStyle(.link)
                        .font(.headline)
                        .foregroundStyle(released ? Color.green : .primary)
                } else {
                    Text(bucket.title).font(.headline)
                }
                Spacer(minLength: 8)
                if released, bucket.tasks.contains(where: { $0.waiting != nil }) {
                    Button("Stop Waiting") { model.stopWaiting(bucket.tasks) }
                        .controlSize(.small)
                }
            }
            if released {
                Text(bucket.tasks.count == 1
                     ? "This landed. 1 task is free to move."
                     : "This landed. \(bucket.tasks.count) tasks are free to move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                // By position: a digest is optional and two identical lines in one project share
                // one, so it is not an identity here.
                ForEach(Array(bucket.tasks.enumerated()), id: \.offset) { _, hit in
                    row(hit, released: released)
                }
            }
        }
    }

    private func symbol(_ bucket: WaitingBucket) -> String {
        switch bucket.state {
        case "released": return "checkmark.circle.fill"
        case "pending": return "clock"
        default: return "person"
        }
    }

    // MARK: One task

    private func row(_ hit: TaskSearchHit, released: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The name, not the markup — a task waiting on one project can name another in its text,
            // and nobody wants to read brackets in a list they're triaging.
            // Italic for an inherited wait, matching the task list's own run — it reads as *reported*
            // rather than as less important, which is the distinction being drawn.
            Text(ProjectIndex.shared.displayText(hit.text))
                .foregroundStyle(released ? .primary : .secondary)
                .italic(hit.waiting == nil)
                .lineLimit(2)
            Spacer(minLength: 8)
            // `showsCode` is read as an `@AppStorage` above so this view is invalidated when the
            // preference flips — the strings built here and in `displayText` both depend on it, and
            // only a binding schedules the redraw.
            Text(ProjectCodes.display(hit.projectFolder, showing: showsCode))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.open(hit) }
        .contextMenu {
            Button("Go to \(ProjectCodes.display(hit.projectFolder))") { model.open(hit) }
            // Only where there's a token to remove. A row that inherits its wait has nothing on its
            // own line to clear, and offering the command anyway would be offering a no-op.
            if hit.waiting != nil {
                Button("Stop Waiting") { model.stopWaiting([hit]) }
            }
        }
    }

    // MARK: Chrome

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing is waiting").font(.headline)
            Text(verbatim: "When a task is held up — by another project, or by somebody else — say so "
                 + "with Waiting On… in its menu. It shows up here until it isn't.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func banner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Include archived projects", isOn: $model.includesArchived)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Rescan every project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
