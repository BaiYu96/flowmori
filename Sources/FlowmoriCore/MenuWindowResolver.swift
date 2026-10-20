import Foundation
import CoreGraphics

/// AppKit window numbers are not WindowServer IDs, including on macOS 26.
public enum MenuWindowResolver {
    /// Reserve enough space for the returning icon as well as its neighbor,
    /// so native reflow cannot place either across the display cutout.
    public static func notchReturnShift(neighbor: CGRect, sourceWidth: CGFloat,
                                        leftEdge: CGFloat, rightEdge: CGFloat) -> CGFloat {
        // The source returns immediately before the neighbor. Testing only the
        // neighbor's leading edge misses a neighbor just right of the cutout
        // whose source slot still overlaps it: native reflow can then push the
        // neighbor left into the cutout and the placement loop oscillates.
        // Reserve space whenever that insertion slot intersects the cutout.
        guard neighbor.minX-sourceWidth < rightEdge else { return 0 }
        return max(0,neighbor.maxX+sourceWidth+8-leftEdge)
    }
    public static func isInsideVisibleMenuRegion(_ window:CGRect,region:CGRect) -> Bool {
        !window.isEmpty && window.minX >= region.minX && window.maxX <= region.maxX &&
        window.midY >= region.minY && window.midY <= region.maxY
    }
    /// AX reports the button bounds, excluding the host window's padding.
    public static func matchesAccessibilityFrame(_ button:CGRect,window:CGRect) -> Bool {
        !button.isEmpty && !window.isEmpty &&
        abs(button.midX-window.midX) <= 2 && abs(button.midY-window.midY) <= 2 &&
        window.insetBy(dx:-2,dy:-2).contains(button) &&
        window.width-button.width <= 32 && window.height-button.height <= 24
    }
    public struct Candidate: Equatable {
        public var id: UInt32
        public var pid: Int32
        public var frame: CGRect
        public init(id:UInt32,pid:Int32,frame:CGRect) { self.id = id; self.pid = pid; self.frame = frame }
    }
    public static func resolve(appKitNumber:Int, frame:CGRect, pid:Int32, candidates:[Candidate]) -> UInt32? {
        guard !frame.isEmpty, frame.origin.x.isFinite, frame.origin.y.isFinite else { return nil }
        let matches = candidates.filter {
            $0.pid == pid && abs($0.frame.minX-frame.minX) <= 2 && abs($0.frame.minY-frame.minY) <= 2 &&
            abs($0.frame.width-frame.width) <= 2 && abs($0.frame.height-frame.height) <= 2
        }
        // A number is only a hint after ownership and geometry have been verified.
        if let hint = UInt32(exactly:appKitNumber), matches.contains(where: { $0.id == hint }) { return hint }
        return matches.count == 1 ? matches[0].id : nil
    }
}

/// Accessibility enumeration runs off the main thread. Its coordinates must
/// belong to the same layout as the WindowServer frames used to resolve owners.
public struct MenuOwnershipSnapshot {
    public let revision: UInt64
    private let windows: [MenuWindowResolver.Candidate]
    public init(revision: UInt64, windows: [MenuWindowResolver.Candidate]) {
        self.revision = revision
        self.windows = windows.sorted { $0.id < $1.id }
    }
    public func isCurrent(revision: UInt64, windows: [MenuWindowResolver.Candidate]) -> Bool {
        self.revision == revision && self.windows == windows.sorted { $0.id < $1.id }
    }
}

/// Reconcile the observed order after each native reorder. WindowServer may
/// reflow other status items, so a single precomputed coordinate is insufficient.
public struct MenuPlacementState {
    public enum Step: Equatable { case complete, move(CGPoint), failed }
    private var attempts = 0
    public init() {}
    public mutating func next(source:CGRect?,neighbor:CGRect?) -> Step {
        guard let source, let neighbor, !source.isEmpty, !neighbor.isEmpty,
              source.minX.isFinite, neighbor.minX.isFinite,
              abs(source.midY-neighbor.midY) < 3 else { return .failed }
        if abs(source.maxX-neighbor.minX) <= 3 { return .complete }
        guard attempts < 3 else { return .failed }
        attempts += 1
        // First get to the neighbor's left side. When approaching from that side,
        // drop inside the neighbor's trailing half: a 1pt inset is treated as the
        // boundary with the next item and can be a no-op for wide source items.
        let inset = min(8, neighbor.width/2)
        let x = source.minX > neighbor.minX ? neighbor.minX+1 : neighbor.maxX-inset
        return .move(CGPoint(x:x,y:neighbor.midY))
    }
}

/// Build an ordered partition without generating input for unknown/system items.
public struct MenuCollectionPlan {
    public struct Item {
        public let id: UInt32
        public let frame: CGRect
        public let manageable: Bool
        public init(id: UInt32, frame: CGRect, manageable: Bool) {
            self.id = id; self.frame = frame; self.manageable = manageable
        }
    }
    public let targets: [UInt32]
    public let retained: [UInt32]
    public init(items: [Item], control: UInt32, divider: UInt32) {
        guard let anchor = items.first(where: { $0.id == control }) else {
            targets = []; retained = []; return
        }
        let row = items.filter {
            $0.id != control && $0.id != divider && abs($0.frame.midY-anchor.frame.midY) < 3
        }.sorted { $0.frame.minX < $1.frame.minX }
        targets = row.filter(\.manageable).map(\.id)
        retained = row.filter { !$0.manageable }.map(\.id)
    }
}

public enum MenuOwnerCachePolicy {
    /// Only temporary absence preserves a verified owner. Identity changes,
    /// process exit, replacement windows and ambiguous matches invalidate it.
    public static func keepCached(identityUnchanged: Bool, sourceAlive: Bool,
                                  protectedSystem: Bool, matchingOwners: Int) -> Bool {
        identityUnchanged && sourceAlive && !protectedSystem && matchingOwners == 0
    }
}

/// WindowServer animates neighboring items for several frames after a reorder.
/// A single frame (or a fixed short sleep) is not a settled insertion position.
public struct MenuLayoutStability {
    private var previous: [MenuWindowResolver.Candidate]?
    private var repeats = 0
    public init() {}
    public mutating func observe(_ windows: [MenuWindowResolver.Candidate]) -> Bool {
        let current = windows.sorted { $0.id < $1.id }
        if current == previous { repeats += 1 } else { repeats = 0 }
        previous = current
        return repeats >= 3
    }
}
