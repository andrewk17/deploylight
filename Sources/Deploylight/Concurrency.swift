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
    typealias Attempt = (Input, Result<[Output], Error>)
    let perform: (Input) async -> Attempt = { input in
        do {
            return (input, .success(try await operation(input)))
        } catch {
            return (input, .failure(error))
        }
    }
    return try await withThrowingTaskGroup(of: Attempt.self) { group in
        let initial = inputs.prefix(max(1, maxConcurrent))
        var pending = inputs.dropFirst(initial.count).makeIterator()
        for input in initial {
            group.addTask { await perform(input) }
        }

        var outputs: [Output] = []
        var firstError: Error?
        var succeeded = false

        while let (input, result) = try await group.next() {
            switch result {
            case let .success(values):
                succeeded = true
                outputs.append(contentsOf: values)
            case let .failure(error):
                if shouldPropagate(error) { throw error }
                try await onFailure(input, error)
                firstError = firstError ?? error
            }
            if let input = pending.next() {
                group.addTask { await perform(input) }
            }
        }

        if !succeeded, let firstError { throw firstError }
        return outputs
    }
}
