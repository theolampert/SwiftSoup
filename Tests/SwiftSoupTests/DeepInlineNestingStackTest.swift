import XCTest
import Foundation
@testable import SwiftSoup

final class DeepInlineNestingStackTest: XCTestCase {

    private func makeNestedHTML(tag: String, depth: Int, inner: String = "x") -> String {
        String(repeating: "<\(tag)>", count: depth) + inner + String(repeating: "</\(tag)>", count: depth)
    }

    /// Runs `body` on a Thread with an explicitly small stack and waits for it.
    /// Returns true if the thread finished cleanly. A stack overflow crashes the
    /// whole process (EXC_BAD_ACCESS) instead.
    private func runOnSmallStack(stackSize: Int, _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = stackSize // bytes, multiple of 4 KiB
        thread.start()
        return done.wait(timeout: .now() + 30) == .success
    }

    private static func deepestElement(of doc: Document) -> Element? {
        var element = doc.body()
        while let child = element?.children().first() {
            element = child
        }
        return element
    }

    // CONTROL: shallow inline nesting on a small stack — must survive.
    func testShallowInlineNestingOnSmallStackSurvives() {
        let html = makeNestedHTML(tag: "b", depth: 50)
        let ok = runOnSmallStack(stackSize: 512 * 1024) {
            _ = try? SwiftSoup.parse(html)
        }
        XCTAssertTrue(ok, "shallow inline nesting should never overflow")
    }

    // REGRESSION: the tree builder marks each inserted formatting element source-dirty.
    // The recursive markSourceDirty walk up the parent chain overflowed at ~4,000 levels.
    func testDeepInlineNestingParseOnSmallStackSurvives() {
        for tag in ["b", "span", "em"] {
            let html = makeNestedHTML(tag: tag, depth: 20_000)
            let ok = runOnSmallStack(stackSize: 512 * 1024) {
                _ = try? SwiftSoup.parse(html)
            }
            XCTAssertTrue(ok, "deep <\(tag)> nesting overflowed the small-stack thread")
        }
    }

    // The iterative walk must keep the recursive semantics: a mutation marks every ancestor source-dirty.
    // Shallow on purpose: the mutation path also calls the recursive ownerDocument(), an overridable hook.
    func testMutationMarksEveryAncestorDirty() throws {
        let doc = try SwiftSoup.parse(makeNestedHTML(tag: "div", depth: 200))
        let deepest = try XCTUnwrap(Self.deepestElement(of: doc))
        try deepest.appendText("y")
        var node: Node? = deepest
        var clean = 0
        while let current = node {
            if !current.sourceRangeDirty { clean += 1 }
            node = current.parentNode
        }
        XCTAssertEqual(clean, 0, "every ancestor of a mutated node is source-dirty")
        XCTAssertEqual(try deepest.text(), "xy")
        XCTAssertTrue(try doc.body()!.html().contains("xy"))
    }
}
