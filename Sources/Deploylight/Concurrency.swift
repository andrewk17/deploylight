private struct ConcurrentAttempt<Output> {
    let index: Int
    let result: Result<[Output], Error>
}

/// Runs `operation` concurrently and concatenates the results.
///
/// Individual failures are tolerated so one inaccessible scope doesn't hide the rest;
/// an error is thrown when every call fails or `shouldPropagate` identifies a fatal error.
/// `onFailure` receives the input and error for each tolerated failure.
func gatherConcurrently<Input, Output>(
    _ inputs: [Input],
    maxConcurrent: Int = .max,
    shouldPropagate: (Error) -> Bool = { _ in false },
    onFailure: @Sendable (Input, Error) async throws -> Void = { _, _ in },
    _ operation: @escaping (Input) async throws -> [Output]
) async throws -> [Output] {
    let perform: (Int) async -> ConcurrentAttempt<Output> = { index in
        do {
            let values = try await operation(inputs[index])
            return ConcurrentAttempt(index: index, result: .success(values))
        } catch {
            return ConcurrentAttempt(index: index, result: .failure(error))
        }
    }
    return try await withThrowingTaskGroup(of: ConcurrentAttempt<Output>.self) { group in
        let initialCount = min(inputs.count, max(1, maxConcurrent))
        for index in 0..<initialCount {
            group.addTask { await perform(index) }
        }
        var nextIndex = initialCount

        var outputs: [Output] = []
        var firstError: Error?
        var succeeded = false

        while let attempt = try await group.next() {
            switch attempt.result {
            case let .success(values):
                succeeded = true
                outputs.append(contentsOf: values)
            case let .failure(error):
                if shouldPropagate(error) { throw error }
                try await onFailure(inputs[attempt.index], error)
                firstError = firstError ?? error
            }
            if nextIndex < inputs.count {
                let index = nextIndex
                nextIndex += 1
                group.addTask { await perform(index) }
            }
        }

        if !succeeded, let firstError { throw firstError }
        return outputs
    }
}
