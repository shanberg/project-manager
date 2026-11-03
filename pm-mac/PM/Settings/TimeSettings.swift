import AppKit
import PmLib
import SwiftUI
import UniformTypeIdentifiers

/// Time: which apps mean you've stopped working, and whether sittings say how long they ran
/// (docs/away-time.md, docs/time-tracking.md D6).
///
/// Both are this Mac's habits rather than facts about a project, so both live in `UserDefaults`.
struct TimeSettingsView: View {
    @AppStorage(AttentionKeeper.showsDurationsKey) private var showsSittingDuration = false
    @State private var apps: [String] = AttentionKeeper.notWorkApps
    @State private var selection: Set<String> = []
    @State private var sites: [String] = AttentionKeeper.notWorkSites
    @State private var siteSelection: Set<String> = []
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                notWorkList
            } header: {
                Text("Not-Work Apps")
            }

            Section {
                notWorkSites
            } header: {
                Text("Not-Work Sites")
            }

            Section {
                Toggle("Show how long each sitting ran", isOn: $showsSittingDuration)
            } footer: {
                Text("A sitting's time is the attention that was on the project while it was the "
                     + "current sitting, not the gap to the next heading. A sitting PM wasn't watching "
                     + "says nothing rather than zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }

    // MARK: Sites

    /// Domains, by the same rules as the apps: select and −, or type one and Return. A browser's front
    /// tab on one of these for a minute ends the span (docs/away-time.md, Browser signals).
    @ViewBuilder
    private var notWorkSites: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $siteSelection) {
                ForEach(sites, id: \.self) { site in
                    Text(site).tag(site)
                }
            }
            .frame(minHeight: 90)
            .contextMenu(forSelectionType: String.self) { chosen in
                Button(chosen.count > 1 ? "Remove \(chosen.count) Sites" : "Remove") { removeSites(chosen) }
            }
            .onDeleteCommand { removeSites(siteSelection) }

            Divider()
            HStack(spacing: 6) {
                TextField("youtube.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSite)
                Button("Add", action: addSite)
                    .disabled(NotWorkSites.normalized(newSite).isEmpty)
                Button { removeSites(siteSelection) } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(siteSelection.isEmpty)
                .help(siteSelection.count > 1 ? "Remove \(siteSelection.count) sites" : "Remove the site")
            }
            .padding(.vertical, 4)
        }
    }

    private func addSite() {
        let domain = NotWorkSites.normalized(newSite)
        guard !domain.isEmpty else { return }
        if !sites.contains(domain) { sites.append(domain) }
        newSite = ""
        AttentionKeeper.notWorkSites = sites
    }

    private func removeSites(_ chosen: Set<String>) {
        sites.removeAll { chosen.contains($0) }
        siteSelection.subtract(chosen)
        AttentionKeeper.notWorkSites = sites
    }

    // MARK: The list

    /// A plain Mac list: select rows, − removes them, + or a drop from Finder adds. No per-row
    /// buttons — acting on several at once is what selection is for.
    @ViewBuilder
    private var notWorkList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(apps, id: \.self) { bundle in
                    AppRow(bundle: bundle).tag(bundle)
                }
            }
            .frame(minHeight: 120)
            .contextMenu(forSelectionType: String.self) { chosen in
                Button(chosen.count > 1 ? "Remove \(chosen.count) Apps" : "Remove") { remove(chosen) }
            }
            .onDeleteCommand { remove(selection) }
            .dropDestination(for: URL.self) { urls, _ in
                add(urls)
                return true
            }

            Divider()
            HStack(spacing: 0) {
                Button { choose() } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("Add an app")
                Divider().frame(height: 16)
                Button { remove(selection) } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .disabled(selection.isEmpty)
                .help(selection.count > 1 ? "Remove \(selection.count) apps" : "Remove the app")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 2)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let bundles = urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        // Folio itself can't be one: being in Folio is the one place attention is certainly on a
        // project.
        let fresh = bundles.filter { !apps.contains($0) && $0 != Bundle.main.bundleIdentifier }
        guard !fresh.isEmpty else { return }
        apps += fresh
        apps.sort { AppRow.name(of: $0).localizedStandardCompare(AppRow.name(of: $1)) == .orderedAscending }
        save()
    }

    private func remove(_ chosen: Set<String>) {
        guard !chosen.isEmpty else { return }
        apps.removeAll(where: chosen.contains)
        selection.subtract(chosen)
        save()
    }

    private func save() {
        AttentionKeeper.notWorkApps = apps
    }
}

/// One app, as Finder would show it: its icon and its name. An app that's since been deleted still
/// shows, by bundle identifier, so it can be removed.
private struct AppRow: View {
    let bundle: String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(of: bundle))
                .resizable()
                .frame(width: 18, height: 18)
            Text(Self.name(of: bundle))
        }
    }

    static func url(of bundle: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    }

    static func name(of bundle: String) -> String {
        guard let url = url(of: bundle) else { return bundle }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of bundle: String) -> NSImage {
        guard let url = url(of: bundle) else {
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
