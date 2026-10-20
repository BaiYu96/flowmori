import Testing
import Foundation
import CoreGraphics
@testable import FlowmoriCore

final class BehaviorTests {
    @Test func testSensitiveAndTransientAndFilesAreNotRecorded() {
        for type in ClipboardPolicy.ignoredTypes.union(["public.file-url"]) {
            #expect(ClipboardPolicy.shouldIgnore(types:[type,"public.utf8-plain-text"],source:"test",exclusions:[]))
        }
        #expect(ClipboardPolicy.shouldIgnore(types:[],source:"secret.app",exclusions:["secret.app"]))
        #expect(!(ClipboardPolicy.shouldIgnore(types:["public.utf8-plain-text"],source:"editor",exclusions:[])))
    }
    @Test func testRetinaCropFlipsOriginAndPreservesPixels() {
        let result = ScreenGeometry.pixelCrop(selection:CGRect(x:100,y:600,width:200,height:100),screen:CGRect(x:0,y:0,width:1440,height:900),pixelWidth:2880,pixelHeight:1800)
        #expect(result == CGRect(x:200,y:400,width:400,height:200))
    }
    @Test func testExternalDisplayWithNegativeOriginAndDifferentScale() {
        let screen = CGRect(x:-1920,y:-300,width:1920,height:1080)
        let selection = CGRect(x:-1900,y:700,width:100,height:40)
        #expect(ScreenGeometry.pixelCrop(selection:selection,screen:screen,pixelWidth:1920,pixelHeight:1080) == CGRect(x:20,y:40,width:100,height:40))
    }
    @Test func testSelectionIsClippedToOneScreen() {
        #expect(ScreenGeometry.pixelCrop(selection:CGRect(x:90,y:90,width:40,height:40),screen:CGRect(x:0,y:0,width:100,height:100),pixelWidth:200,pixelHeight:200) == CGRect(x:180,y:0,width:20,height:20))
        #expect(ScreenGeometry.pixelCrop(selection:CGRect(x:200,y:200,width:20,height:20),screen:CGRect(x:0,y:0,width:100,height:100),pixelWidth:200,pixelHeight:200) == .zero)
    }
    @Test func testPopupNeverExtendsOutsideVisibleFrame() {
        let visible = CGRect(x:-1920,y:0,width:1920,height:1080)
        let panel = ScreenGeometry.clamped(CGRect(x:-10,y:-20,width:430,height:540),to:visible)
        #expect(visible.contains(panel)); #expect(panel.maxX == 0)
    }
    @Test func testVeryWideAndTallPinsRemainZoomable() {
        let screen = CGRect(x:0,y:0,width:1400,height:900)
        for size in [CGSize(width:600,height:6),CGSize(width:6,height:600)] {
            let original = CGRect(origin:CGPoint(x:100,y:100),size:size)
            let shrunk = ScreenGeometry.scaledImageFrame(original,factor:0.5,available:screen)
            #expect(shrunk.width == size.width*0.5)
            #expect(shrunk.height == size.height*0.5)
            #expect(screen.contains(shrunk))
        }
    }
    @Test func testPinFitsSmallerReplacementDisplayWithoutDistortion() {
        let screen = CGRect(x:-1280,y:0,width:1280,height:720)
        let original = CGRect(x:2000,y:100,width:1600,height:1000)
        let result = ScreenGeometry.scaledImageFrame(original,factor:1,available:screen)
        #expect(screen.contains(result))
        #expect(abs(result.width/result.height-1.6) < 0.0001)
    }
    @Test func testMenuOperationsCannotOverlapAndRecoverAfterFailure() {
        var state = MenuOperationState()
        let first = state.begin(12), overlapping = state.begin(13)
        #expect(first); #expect(!overlapping)
        state.didMove(); #expect(state.phase == .interacting)
        state.restore(); #expect(state.phase == .restoring)
        state.fail(); let whileFailed = state.begin(14); #expect(!whileFailed)
        state.finish(); #expect(state.phase == .idle); #expect(state.windowID == nil)
        let recovered = state.begin(15); #expect(recovered)
    }
}
