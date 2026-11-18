import Foundation

struct ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let version = value.hasPrefix("v") ? String(value.dropFirst()) : value
        // Stable releases only. Build metadata doesn't affect semantic precedence.
        let parts = version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].contains("-") else { return nil }
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            } }) else { return nil }
        }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        let parsed = numbers.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part.count == 1 || part.first != "0" else { return nil }
            return Int(part)
        }
        guard parsed.count == 3 else { return nil }
        (major, minor, patch) = (parsed[0], parsed[1], parsed[2])
    }

    var tag: String { "v\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AvailableUpdate: Equatable {
    let version: ReleaseVersion
    let url: URL
}

@MainActor
final class UpdateChecker {
    private struct Release: Decodable {
        let tag_name: String
        let prerelease: Bool
        let draft: Bool
    }

    private let session: URLSession
    private let runningVersion: ReleaseVersion?
    static let lastAttemptKey = "DeploylightUpdateLastAttempt"
    private let userDefaults: UserDefaults
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?
    private var enabled = false
    private(set) var available: AvailableUpdate?

    init(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         session: URLSession? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        lastAttempt = userDefaults.object(forKey: Self.lastAttemptKey) as? Date
        runningVersion = version.flatMap(ReleaseVersion.init)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration)
    }

    // Called at launch, on preference changes, and periodically (also catches wake from sleep).
    @discardableResult
    func checkIfDue(enabled: Bool, now: Date = Date()) -> Task<Void, Never>? {
        self.enabled = enabled
        guard enabled else {
            stop()
            available = nil
            return nil
        }
        guard let runningVersion, task == nil,
              lastAttempt.map({ now.timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true else { return nil }
        lastAttempt = now // Failures wait a day too, including across relaunches.
        userDefaults.set(now, forKey: Self.lastAttemptKey)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/andrewk17/deploylight/releases/latest")!)
            request.timeoutInterval = 8
            request.setValue("Deploylight-Update-Check", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await self.session.data(for: request)
                guard !Task.isCancelled, self.enabled,
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard !release.prerelease, !release.draft,
                      let version = ReleaseVersion(release.tag_name), version > runningVersion,
                      let url = URL(string: "https://github.com/andrewk17/deploylight/releases/tag/\(release.tag_name)") else {
                    self.available = nil
                    return
                }
                self.available = AvailableUpdate(version: version, url: url)
            } catch {
                // Update checks are optional: offline/rate-limit/decoding errors stay silent.
            }
        }
        return task
    }

    func stop() {
        task?.cancel()
        // Keep the task until its cancellation completes, so its defer cannot clear a new task.
    }
}
