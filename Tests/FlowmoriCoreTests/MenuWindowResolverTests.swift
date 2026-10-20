import Testing
import CoreGraphics
@testable import FlowmoriCore

struct MenuWindowResolverTests {
    let frame = CGRect(x:800,y:0,width:20,height:32)
    @Test func ownershipScanRejectsMovedWindowsInsteadOfUsingStaleCoordinates() {
        let original = MenuWindowResolver.Candidate(id:10,pid:689,frame:CGRect(x:765,y:0,width:52,height:33))
        let snapshot = MenuOwnershipSnapshot(revision:4,windows:[original])
        let collapsed = MenuWindowResolver.Candidate(id:10,pid:689,frame:original.frame.offsetBy(dx:-3006,dy:0))
        #expect(!snapshot.isCurrent(revision:4,windows:[collapsed]))
        #expect(snapshot.isCurrent(revision:4,windows:[original]))
    }
    @Test func ownershipScanRejectsAMoveAndReturnEvenWhenFinalCoordinatesMatch() {
        let window = MenuWindowResolver.Candidate(id:10,pid:689,frame:frame)
        let snapshot = MenuOwnershipSnapshot(revision:4,windows:[window])
        // The AX scan can observe the temporary visible position while both
        // before/after WindowServer snapshots observe the original position.
        #expect(!snapshot.isCurrent(revision:6,windows:[window]))
    }
    @Test func ownershipSnapshotAcceptsReorderedEnumerationButRejectsReplacement() {
        let a = MenuWindowResolver.Candidate(id:10,pid:689,frame:frame)
        let b = MenuWindowResolver.Candidate(id:11,pid:690,frame:frame.offsetBy(dx:20,dy:0))
        let snapshot = MenuOwnershipSnapshot(revision:1,windows:[a,b])
        #expect(snapshot.isCurrent(revision:1,windows:[b,a]))
        #expect(!snapshot.isCurrent(revision:1,windows:[a]))
        #expect(!snapshot.isCurrent(revision:1,windows:[a,.init(id:11,pid:691,frame:b.frame)]))
    }
    @Test func nativeReflowIsReconciledFromObservedNeighborPosition() {
        for offset in [CGFloat(0),CGFloat(-6)] {
            var placement = MenuPlacementState()
            let source = CGRect(x:1149,y:0,width:52,height:33)
            #expect(placement.next(source:source,neighbor:CGRect(x:729+offset,y:0,width:34,height:33)) == .move(CGPoint(x:730+offset,y:16.5)))
            // Recorded failure: the first drop can land one slot too far left.
            #expect(placement.next(source:CGRect(x:677+offset,y:0,width:52,height:33),neighbor:CGRect(x:781+offset,y:0,width:34,height:33)) == .move(CGPoint(x:807+offset,y:16.5)))
            #expect(placement.next(source:CGRect(x:729+offset,y:0,width:52,height:33),neighbor:CGRect(x:781+offset,y:0,width:34,height:33)) == .complete)
        }
    }
    @Test func insertingBeforeNeighborDropsInsideTrailingHalf() {
        var placement = MenuPlacementState()
        #expect(placement.next(source:CGRect(x:732,y:0,width:64,height:33),neighbor:CGRect(x:830,y:0,width:38,height:33)) == .move(CGPoint(x:860,y:16.5)))
    }
    @Test func missingOrUnchangingLayoutStopsPlacement() {
        var missing = MenuPlacementState()
        #expect(missing.next(source:frame,neighbor:nil) == .failed)
        var stalled = MenuPlacementState()
        for _ in 0..<3 {
            #expect(stalled.next(source:frame,neighbor:frame.offsetBy(dx:-100,dy:0)) != .failed)
        }
        #expect(stalled.next(source:frame,neighbor:frame.offsetBy(dx:-100,dy:0)) == .failed)
    }
    @Test func alreadyRestoredLayoutDoesNotSendAnotherMove() {
        var placement = MenuPlacementState()
        #expect(placement.next(source:frame,neighbor:frame.offsetBy(dx:20,dy:0)) == .complete)
    }
    @Test func virtualAppKitWindowNumberDoesNotOverflowAndMatchesGeometry() {
        let result = MenuWindowResolver.resolve(appKitNumber:8_589_934_592,frame:frame,pid:42,
            candidates:[.init(id:100,pid:42,frame:frame)])
        #expect(result == 100)
    }
    @Test func unrelatedWindowNumberNeverOverridesOwnershipOrGeometry() {
        #expect(MenuWindowResolver.resolve(appKitNumber:100,frame:frame,pid:42,
            candidates:[.init(id:100,pid:43,frame:frame)]) == nil)
        #expect(MenuWindowResolver.resolve(appKitNumber:100,frame:frame,pid:42,
            candidates:[.init(id:100,pid:42,frame:frame.offsetBy(dx:24,dy:0))]) == nil)
    }
    @Test func absentOrAmbiguousWindowsDoNotProduceAGuessedTarget() {
        #expect(MenuWindowResolver.resolve(appKitNumber:-1,frame:frame,pid:42,candidates:[]) == nil)
        #expect(MenuWindowResolver.resolve(appKitNumber:-1,frame:frame,pid:42,
            candidates:[.init(id:1,pid:42,frame:frame),.init(id:2,pid:42,frame:frame)]) == nil)
    }
    @Test func accessibilityButtonMatchesPaddedHostWindowOnly() {
        let button = CGRect(x:766,y:4.5,width:38,height:24)
        let host = CGRect(x:759,y:0,width:52,height:33)
        #expect(MenuWindowResolver.matchesAccessibilityFrame(button,window:host))
        #expect(!MenuWindowResolver.matchesAccessibilityFrame(button,window:host.offsetBy(dx:52,dy:0)))
        #expect(!MenuWindowResolver.matchesAccessibilityFrame(button,window:CGRect(x:0,y:0,width:1570,height:33)))
    }
    @Test func paddedWindowHeightIsAllowedButNotchOverlapIsRejected() {
        let safe = CGRect(x:850,y:950,width:662,height:32)
        #expect(MenuWindowResolver.isInsideVisibleMenuRegion(CGRect(x:1100,y:949,width:52,height:33),region:safe))
        #expect(!MenuWindowResolver.isInsideVisibleMenuRegion(CGRect(x:835,y:949,width:52,height:33),region:safe))
        #expect(!MenuWindowResolver.isInsideVisibleMenuRegion(CGRect(x:1100,y:900,width:52,height:33),region:safe))
    }
}

struct MenuCollectionTests {
    @Test func collectionKeepsSystemAndUnknownAndPreservesApplicationOrder() {
        func item(_ id:UInt32,_ x:CGFloat,_ manageable:Bool,_ y:CGFloat = 0) -> MenuCollectionPlan.Item {
            .init(id:id,frame:CGRect(x:x,y:y,width:24,height:32),manageable:manageable)
        }
        // Divider is behind the notch, control misplaced among application icons.
        let plan = MenuCollectionPlan(items:[item(5,950,true),item(1,700,true),item(2,800,false),
            item(3,850,true),item(4,900,false),item(6,1000,false),item(7,1050,false),item(8,50,true,1000)],control:3,divider:2)
        #expect(plan.targets == [1,5])
        #expect(plan.retained == [4,6,7])
        #expect(!plan.targets.contains(8)) // different menu-bar row/display
    }
    @Test func missingControlCannotGenerateMoves() {
        let plan = MenuCollectionPlan(items:[.init(id:1,frame:CGRect(x:0,y:0,width:24,height:32),manageable:true)],control:2,divider:3)
        #expect(plan.targets.isEmpty && plan.retained.isEmpty)
    }
    @Test func temporaryAbsenceIsDifferentFromConflictOrReplacement() {
        #expect(MenuOwnerCachePolicy.keepCached(identityUnchanged:true,sourceAlive:true,protectedSystem:false,matchingOwners:0))
        #expect(!MenuOwnerCachePolicy.keepCached(identityUnchanged:false,sourceAlive:true,protectedSystem:false,matchingOwners:0))
        #expect(!MenuOwnerCachePolicy.keepCached(identityUnchanged:true,sourceAlive:false,protectedSystem:false,matchingOwners:0))
        #expect(!MenuOwnerCachePolicy.keepCached(identityUnchanged:true,sourceAlive:true,protectedSystem:true,matchingOwners:0))
        #expect(!MenuOwnerCachePolicy.keepCached(identityUnchanged:true,sourceAlive:true,protectedSystem:false,matchingOwners:2))
    }
}

struct MenuLayoutStabilityTests {
    @Test func recordedAnimationMustSettleBeforePlacementIsChecked() {
        var state = MenuLayoutStability()
        // Native build 9 trace: a neighbor continues moving well after 250 ms.
        for x in [879,827,832,835,837,825,826] {
            #expect(state.observe([.init(id:225,pid:689,frame:CGRect(x:x,y:0,width:44,height:33))]) == false)
        }
        let final = [MenuWindowResolver.Candidate(id:225,pid:689,frame:CGRect(x:826,y:0,width:44,height:33))]
        #expect(state.observe(final) == false)
        #expect(state.observe(final) == false)
        #expect(state.observe(final) == true)
        #expect(state.observe([.init(id:226,pid:689,frame:final[0].frame)]) == false)
    }
    @Test func enumerationOrderDoesNotRestartSettling() {
        var state = MenuLayoutStability()
        let a = MenuWindowResolver.Candidate(id:1,pid:1,frame:CGRect(x:0,y:0,width:20,height:33))
        let b = MenuWindowResolver.Candidate(id:2,pid:1,frame:CGRect(x:20,y:0,width:20,height:33))
        #expect(state.observe([a,b]) == false)
        #expect(state.observe([b,a]) == false)
        #expect(state.observe([a,b]) == false)
        #expect(state.observe([b,a]) == true)
    }
}

struct MenuNotchReturnTests {
    @Test func insertionReservesBothWidthsOutsideTheCutout() {
        let neighbor = CGRect(x:775,y:0,width:64,height:33)
        let shift = MenuWindowResolver.notchReturnShift(neighbor:neighbor,sourceWidth:52,leftEdge:665,rightEdge:850)
        #expect(shift == 234)
        #expect(neighbor.maxX-shift+52 < 665)
        // The slot [858,910] sits entirely right of the cutout.
        #expect(MenuWindowResolver.notchReturnShift(neighbor:CGRect(x:910,y:0,width:64,height:33),sourceWidth:52,leftEdge:665,rightEdge:850) == 0)
        #expect(MenuWindowResolver.notchReturnShift(neighbor:CGRect(x:500,y:0,width:64,height:33),sourceWidth:52,leftEdge:665,rightEdge:850) == 0)
    }
    @Test func insertionSlotJustRightOfCutoutStillReservesSpace() {
        // Build 10: the neighbor was at 888 (right of the 850 edge), so the old
        // neighbor-only test returned no shift even though the returning slot
        // [836,888] still intersected the cutout.
        let neighbor = CGRect(x:888,y:0,width:64,height:33)
        let shift = MenuWindowResolver.notchReturnShift(neighbor:neighbor,sourceWidth:52,leftEdge:665,rightEdge:850)
        #expect(shift == 347)
        #expect(neighbor.maxX-shift+52 <= 665)
        // Recorded trace: after the unshifted drop, reflow moved this neighbor
        // from 871 to 775 (inside the cutout) and the placement loop oscillated.
        #expect(MenuWindowResolver.notchReturnShift(neighbor:CGRect(x:871,y:0,width:64,height:33),sourceWidth:52,leftEdge:665,rightEdge:850) > 0)
        // A two-point overlap is still an overlap; the divider must shift.
        #expect(MenuWindowResolver.notchReturnShift(neighbor:CGRect(x:912,y:0,width:40,height:33),sourceWidth:64,leftEdge:665,rightEdge:850) == 359)
        // A slot that fits entirely right of the cutout still needs no shift.
        #expect(MenuWindowResolver.notchReturnShift(neighbor:CGRect(x:960,y:0,width:48,height:33),sourceWidth:52,leftEdge:665,rightEdge:850) == 0)
    }
}
