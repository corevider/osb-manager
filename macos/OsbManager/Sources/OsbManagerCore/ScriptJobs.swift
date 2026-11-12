import Foundation

@MainActor
public final class ScriptJobs {
    @MainActor
    public final class Job {
        private let owner: ScriptJobs
        private var ended = false

        fileprivate init(owner: ScriptJobs) {
            self.owner = owner
        }

        public func end() {
            guard !ended else { return }
            ended = true
            owner.active -= 1
        }
    }

    fileprivate var active = 0

    public init() {}

    public var busy: Bool { active > 0 }

    public func begin() -> Job {
        active += 1
        return Job(owner: self)
    }
}
