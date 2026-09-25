import AppKit
import PmLib
import SwiftUI
import UniformTypeIdentifiers

/// Project Settings' image icon, under the Icon row's Image choice: the image as it will be drawn, a
/// Replace button that is always there, and whether Folio recolours it.
///
/// Laid out like the texture's image panel, so the two read as the same kind of control.
struct ProjectIconImagePanel: View {
    @Bindable var model: ProjectSettingsModel

    @State private var isTargeted = false

    /// SVG or PNG: an icon wants a shape with a transparent ground, and those are the two that carry one.
    static let types: [UTType] = [.svg, .png]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                preview.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.iconImageName ?? "No image chosen")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.iconImageName == nil ? .secondary : .primary)
                    Text("An SVG or PNG, or SVG code you've copied.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Paste") { pasteImage() }
                    .help("Use the SVG or PNG on the clipboard — an icon site's Copy SVG works")
                Button(model.iconImageName == nil ? "Choose…" : "Replace…") { chooseImage() }
            }
            HStack(spacing: 10) {
                Text("Colors").font(.system(size: 12))
                Picker("Colors", selection: $model.iconRecolor) {
                    Text("Original").tag(false)
                    Text("Project Color").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Self.acceptDrop(providers) { model.chooseIconImage($0) }
        }
        .onPasteCommand(of: [.fileURL, .svg, .png, .plainText]) { _ in pasteImage() }
    }

    private func pasteImage() {
        guard let pasted = Self.pastedIcon(from: .general) else { NSSound.beep(); return }
        model.chooseIconImage(pasted.file)
        if pasted.tinted { model.iconRecolor = true }
    }

    /// The icon on a pasteboard, as a file to choose: an SVG or PNG file copied in the Finder, or SVG
    /// markup — which is what an icon site's Copy SVG hands over — written to a file of its own. Nil
    /// when there's neither.
    ///
    /// `tinted` is for markup drawn in `currentColor`: the icon set means it to take the colour of
    /// wherever it's put, so it starts out in the project's colour rather than black.
    static func pastedIcon(from pasteboard: NSPasteboard) -> (file: URL, tinted: Bool)? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                      as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), types.contains(where: type.conforms(to:)) {
            return (url, false)
        }
        let text = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
            .flatMap { String(data: $0, encoding: .utf8) } ?? pasteboard.string(forType: .string)
        if let markup = text.flatMap(pastedSVGMarkup), let file = try? written(Data(markup.utf8), named: "icon.svg") {
            return (file, svgUsesCurrentColor(markup))
        }
        if let png = pasteboard.data(forType: .png), let file = try? written(png, named: "icon.png") {
            return (file, false)
        }
        return nil
    }

    /// A file to hold a pasted icon until Save copies it in beside the notes.
    private static func written(_ contents: Data, named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folio pasted icon \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try contents.write(to: file)
        return file
    }

    /// The icon at the size of the preview, on the sheet's ground — or an empty well to drop onto.
    @ViewBuilder
    private var preview: some View {
        if let icon = model.drawableIcon, ProjectIconMark.canDraw(icon) {
            ProjectIconMark(icon: icon, size: 30, tint: model.color?.swiftUIColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SVG or PNG to use as the icon."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseIconImage(url)
    }

    /// An SVG or PNG dropped on the icon controls becomes the icon.
    static func acceptDrop(_ providers: [NSItemProvider], choose: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let type = UTType(filenameExtension: url.pathExtension),
                  types.contains(where: type.conforms(to:)) else { return }
            DispatchQueue.main.async { choose(url) }
        }
        return true
    }
}
