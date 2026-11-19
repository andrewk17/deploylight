/// Runs `operation` concurrently and concatenates the results.
///
/// Individual failures are tolerated so one inaccessible scope doesn't hide the rest;
/// an error is thrown when every call fails or `shouldPropagate` identifies a fatal error.
func gatherConcurrently<Input, Output>(
    _ inputs: [Input],
    maxConcurrent: Int = .max,
    shouldPropagate: (Error) -> Bool = { _ in false },
    _ operation: @escaping (Input) async throws -> [Output]
) async throws -> [Output] {
    let perform: (Input) async -> Result<[Output], Error> = { input in
        do {
            return .success(try await operation(input))
        } catch {
            return .failure(error)
        }
    }
    return try await withThrowingTaskGroup(of: Result<[Output], Error>.self) { group in
        let initial = inputs.prefix(max(1, maxConcurrent))
        var pending = inputs.dropFirst(initial.count).makeIterator()
        for input in initial {
            group.addTask { await perform(input) }
        }

        var outputs: [Output] = []
        var firstError: Error?
        var succeeded = false

        while let result = try await group.next() {
            switch result {
            case let .success(values):
                succeeded = true
                outputs.append(contentsOf: values)
            case let .failure(error):
                if shouldPropagate(error) { throw error }
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
