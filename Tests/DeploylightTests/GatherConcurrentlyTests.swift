import XCTest
@testable import Deploylight

final class GatherConcurrentlyTests: XCTestCase {
    private struct Failure: Error {}

    private actor FailedInputs {
        private(set) var values: [String] = []

        func record(_ input: String) {
            values.append(input)
        }
    }

    func testToleratesPartialFailure() async throws {
        let result = try await gatherConcurrently([1, 2, 3]) { value -> [Int] in
            if value == 2 { throw Failure() }
            return [value]
        }
        XCTAssertEqual(result.sorted(), [1, 3])
    }

    func testThrowsWhenEveryCallFails() async {
        do {
            _ = try await gatherConcurrently([1, 2]) { _ -> [Int] in throw Failure() }
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is Failure)
        }
    }

    func testReturnsEachSuccessfulOutputOnceWithBoundedConcurrency() async throws {
        let inputs = (0..<64).map { "deployment-scope-\($0)" }
        let expectedFailures = Set(stride(from: 0, to: inputs.count, by: 5).map { inputs[$0] })
        let failedInputs = FailedInputs()

        let result = try await gatherConcurrently(inputs, maxConcurrent: 4, onFailure: { input, error in
            XCTAssertTrue(error is Failure)
            await failedInputs.record(input)
        }) { input -> [String] in
            await Task.yield()
            if expectedFailures.contains(input) { throw Failure() }
            return [input, "\(input)-history"]
        }

        let expectedOutputs = inputs.filter { !expectedFailures.contains($0) }.flatMap { [$0, "\($0)-history"] }
        let failures = await failedInputs.values
        XCTAssertEqual(result.sorted(), expectedOutputs.sorted())
        XCTAssertEqual(failures.sorted(), expectedFailures.sorted())
    }

    func testEmptyInputReturnsEmpty() async throws {
        let result = try await gatherConcurrently([Int]()) { _ -> [Int] in throw Failure() }
        XCTAssertEqual(result, [])
    }
}
