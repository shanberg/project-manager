import AppKit

/// Gather by where the windows are: a popped-out workspace's satellites, as wherever they have been
/// moved, read back into columns of tiles. See `CanvasBoardView.gatherWorkspace`.
///
/// **Columns left to right, tiles top to bottom.** A window joins a column when it overlaps the column
/// across by more than half of the narrower of the two — windows stacked roughly above one another are
/// one column, windows side by side are two. Widths and heights are shared in proportion to the windows'
/// own, so a big window comes back as a big tile.
///
/// Screen coordinates, so up is +y: the top of a column is the window with the highest top edge.
enum CanvasSatelliteGather {
    static func columns(from windows: [(tile: CanvasTiling.Tile, frame: NSRect)]) -> [CanvasTiling.Column] {
        struct Run {
            var minX: CGFloat
            var maxX: CGFloat
            var members: [(tile: CanvasTiling.Tile, frame: NSRect)]
        }
        var runs: [Run] = []
        for window in windows.filter({ !$0.tile.cards.isEmpty }).sorted(by: { $0.frame.midX < $1.frame.midX }) {
            let frame = window.frame
            let joins = runs.firstIndex { run in
                let overlap = min(run.maxX, frame.maxX) - max(run.minX, frame.minX)
                return overlap > min(run.maxX - run.minX, frame.width) / 2
            }
            if let joins {
                runs[joins].minX = min(runs[joins].minX, frame.minX)
                runs[joins].maxX = max(runs[joins].maxX, frame.maxX)
                runs[joins].members.append(window)
            } else {
                runs.append(Run(minX: frame.minX, maxX: frame.maxX, members: [window]))
            }
        }
        runs.sort { $0.minX < $1.minX }
        let across = runs.reduce(0) { $0 + ($1.maxX - $1.minX) }
        guard across > 0 else { return [] }
        return runs.map { run in
            let members = run.members.sorted { $0.frame.maxY > $1.frame.maxY }
            let down = members.reduce(0) { $0 + $1.frame.height }
            let tiles = members.map { member in
                var tile = member.tile
                tile.height = .flexible(down > 0 ? Double(member.frame.height / down) : 1)
                return tile
            }
            return CanvasTiling.Column(width: .flexible(Double((run.maxX - run.minX) / across)), tiles)
        }
    }
}
