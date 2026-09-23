import AppKit
import PmLib
import SwiftUI
import UniformTypeIdentifiers

extension ProjectTexture.Name {
    /// "Weave" — for a tooltip and for VoiceOver.
    var displayName: String { rawValue.capitalized }
}

/// Project Settings' texture controls, under the Texture row's None / Pattern / Image switch: the
/// patterns or the image, a preview drawn by the board's own renderer, and how the texture is laid on.
///
/// **An image is a mode of its own, not a thirteenth swatch.** As a swatch it sat in the grid looking
/// like a pattern, and once chosen there was nothing to say it could be chosen again. Here it has its
/// name, what it will look like, and a Replace button that is always there.
///
/// Swatches and preview are inked in the colour chosen in the row above, so what you pick is what the
/// window will show.
struct ProjectTexturePanel: View {
    @Bindable var model: ProjectSettingsModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    private static let swatch: CGFloat = 26
    /// The preview is a window in miniature this tall, of which only the top `previewShown` is shown:
    /// the corner is where the texture is.
    private static let previewHeight: CGFloat = 160
    private static let previewShown: CGFloat = 64
    private let columns = Array(repeating: GridItem(.fixed(swatch + 4), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.textureMode {
            case .pattern: patternGrid
            case .image: imagePanel
            case .none: EmptyView()
            }
            preview
            controls
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            ProjectTexturePanel.acceptDrop(providers) { model.chooseTextureImage($0) }
        }
    }

    /// An image file dropped on the texture controls becomes the texture.
    static func acceptDrop(_ providers: [NSItemProvider], choose: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, isMarkdownImagePath(url.path) else { return }
            DispatchQueue.main.async { choose(url) }
        }
        return true
    }

    // MARK: Pattern

    private var patternGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(ProjectTexture.Name.allCases, id: \.self) { name in
                let selected = model.texturePattern == name
                Button {
                    model.texturePattern = name
                } label: {
                    swatch(CanvasTexture.tile(rows: CanvasTexture.rows(name)), size: Self.swatch)
                        .padding(2)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name.displayName)
                .accessibilityLabel(Text("\(name.displayName) Texture"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Image

    private var imagePanel: some View {
        HStack(spacing: 12) {
            Group {
                if let tile = model.textureImageTile {
                    swatch(tile, size: 44)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.textureImageName ?? "No image chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.textureImageName == nil ? .secondary : .primary)
                Text("Dithered to one bit and tiled.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(model.textureImageName == nil ? "Choose…" : "Replace…") { chooseImage() }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to dither into a texture."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseTextureImage(url)
    }

    // MARK: Preview and controls

    /// The board's own ground as a window in miniature, clipped to its top strip: the same renderer, so
    /// the preview can't disagree with the window. Pixels are their real size, the reach is sized to the
    /// miniature as it is to a pane, and the wash is scaled to match. The window behind the sheet shows
    /// the real thing as you choose.
    private var preview: some View {
        TexturePreview(color: model.color, texture: model.previewTexture)
            .frame(height: Self.previewHeight)
            .frame(height: Self.previewShown, alignment: .top)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .overlay(alignment: .bottomLeading) {
                if CanvasTexture.isSuppressed {
                    Text("Textures are hidden while Increase Contrast or Reduce Transparency is on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .accessibilityHidden(true)
    }

    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Reach")
                Picker("Reach", selection: $model.textureStyle.reach) {
                    Text("Short").tag(ProjectTextureStyle.Reach.short)
                    Text("Medium").tag(ProjectTextureStyle.Reach.medium)
                    Text("Long").tag(ProjectTextureStyle.Reach.long)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .gridCellColumns(2)
            }
            GridRow {
                Text("Strength")
                Slider(value: percent(\.strength), in: range(ProjectTextureStyle.strengthRange))
                Text("\(model.textureStyle.strength)%").monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            GridRow {
                Text("Pixel")
                Picker("Pixel", selection: $model.textureStyle.pixel) {
                    ForEach(Array(ProjectTextureStyle.pixelRange), id: \.self) { Text("\($0) pt").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .gridCellColumns(2)
            }
            if model.textureMode == .image {
                GridRow {
                    Text("Tile")
                    Slider(value: percent(\.tile), in: range(ProjectTextureStyle.tileRange))
                    // In points on the board: cells times the pixel size.
                    Text("\(model.textureStyle.tile * model.textureStyle.pixel) pt")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
    }

    private func percent(_ key: WritableKeyPath<ProjectTextureStyle, Int>) -> Binding<Double> {
        Binding { Double(model.textureStyle[keyPath: key]) } set: { model.textureStyle[keyPath: key] = Int($0.rounded()) }
    }

    private func range(_ range: ClosedRange<Int>) -> ClosedRange<Double> {
        Double(range.lowerBound)...Double(range.upperBound)
    }

    // MARK: Swatches

    private func swatch(_ tile: CanvasTexture.Tile, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor))
            if let image = Self.swatchImage(tile, cells: Int(size), color: model.color, dark: colorScheme == .dark) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor))
        }
        .frame(width: size, height: size)
    }

    /// The tile across a swatch, one bitmap pixel per cell. Cells of 1pt rather than the board's 2pt:
    /// at the board's size a swatch holds barely one repeat, and a pattern is its repeats.
    static func swatchImage(_ tile: CanvasTexture.Tile, cells: Int, color: ProjectColor?, dark: Bool) -> CGImage? {
        let rgb = color?.nsColor.usingColorSpace(.sRGB).map {
            (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent))
        }
        let ink = CanvasTexture.ink(for: rgb, dark: dark)
        let alpha = 0.55
        let channels = [ink.0 * alpha, ink.1 * alpha, ink.2 * alpha, alpha].map { UInt8(($0 * 255).rounded()) }
        var pixels = [UInt8](repeating: 0, count: cells * cells * 4)
        // A solid tile is Dither, whose texture is the feather itself — so its swatch is a fade, not a fill.
        let isSolid = !tile.bits.contains(false)
        for y in 0..<cells {
            for x in 0..<cells where tile.isInk(x, y) {
                if isSolid, (Double(CanvasTexture.bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64 > 1 - Double(x) / Double(cells) {
                    continue
                }
                let base = (y * cells + x) * 4
                pixels.replaceSubrange(base..<base + 4, with: channels)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: cells, height: cells, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cells * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// A `CanvasColorWash` in the sheet, for the preview.
private struct TexturePreview: NSViewRepresentable {
    let color: ProjectColor?
    let texture: CanvasTexture.Spec?

    /// A typical project window's height, for scaling the wash down to the preview's.
    private static let windowHeight: CGFloat = 760

    func makeNSView(context: Context) -> CanvasColorWash {
        let view = CanvasColorWash(frame: .zero)
        view.ground = CanvasPalette.board
        view.postsFrameChangedNotifications = true
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CanvasColorWash, context: Context) -> CGSize? {
        let size = CGSize(width: proposal.width ?? 360, height: proposal.height ?? 200)
        nsView.washHeight = (CanvasColorWash.height * size.height / Self.windowHeight).rounded()
        return size
    }

    func updateNSView(_ view: CanvasColorWash, context: Context) {
        view.color = color
        view.texture = texture
    }
}
