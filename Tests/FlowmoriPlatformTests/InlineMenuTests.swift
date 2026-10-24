import Testing
import ApplicationServices
@testable import Flowmori

@Suite struct InlineMenuTests {
    private func node(_ title: String, enabled: Bool = true, canPress: Bool = true,
                      children: [InlineMenuNode] = []) -> InlineMenuNode {
        InlineMenuNode(title:title,enabled:enabled,checked:false,shortcut:nil,canPress:canPress,children:children)
    }
    @Test func changedMenuCannotReuseSnapshotIndex() throws {
        let expected = try #require(InlineMenuSelection.levels(nodes:[node("打开"),node("退出")],path:[0]))
        #expect(InlineMenuSelection.matches(["打开","退出"],expected:expected,depth:0))
        #expect(!InlineMenuSelection.matches(["退出","打开"],expected:expected,depth:0))
        #expect(!InlineMenuSelection.matches(["新项目","打开","退出"],expected:expected,depth:0))
        #expect(!InlineMenuSelection.matches(["退出"],expected:expected,depth:0))
    }
    @Test func nestedMenuValidatesEveryLevel() throws {
        let expected = try #require(InlineMenuSelection.levels(nodes:[node("模式",children:[node("自动"),node("手动")])],path:[0,1]))
        #expect(expected == [["模式"],["自动","手动"]])
        #expect(!InlineMenuSelection.matches(["手动","自动"],expected:expected,depth:1))
        #expect(!InlineMenuSelection.matches([],expected:expected,depth:2))
    }
    @Test func nonActionableAndInvalidPathsAreRejected() {
        #expect(InlineMenuSelection.levels(nodes:[node("禁用",enabled:false)],path:[0]) == nil)
        #expect(InlineMenuSelection.levels(nodes:[node("自定义",canPress:false)],path:[0]) == nil)
        #expect(InlineMenuSelection.levels(nodes:[node("打开")],path:[1]) == nil)
        #expect(InlineMenuSelection.levels(nodes:[node("打开")],path:[]) == nil)
        #expect(InlineMenuSelection.levels(nodes:[node("父级",children:[node("子级")])],path:[0]) == nil)
    }
    @Test func cancelledPreparationDiscardsLateWorkerResult() {
        let request = InlinePreparationRequest()
        #expect(request.read() == nil)
        request.cancel()
        request.complete(InlineMenuPreparation(nodes:[],action:"AXPress",supported:[],error:.success,failure:nil))
        #expect(request.isCancelled)
        #expect(request.read() == nil)
    }
    @Test func preparationPublishesResultBeforeCancellation() {
        let request = InlinePreparationRequest()
        request.complete(InlineMenuPreparation(nodes:[],action:"AXPress",supported:[],error:.cannotComplete,failure:.noMenu))
        #expect(request.read()?.action == "AXPress")
    }
}
