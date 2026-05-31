import Foundation
import VopauseCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func expectBecameActive(_ commits: [MicActivityCommit], _ message: String) {
    guard commits.count == 1, case .becameActive = commits[0] else {
        preconditionFailure(message)
    }
}

func expectBecameInactive(_ commits: [MicActivityCommit], _ message: String) {
    guard commits.count == 1, case .becameInactive = commits[0] else {
        preconditionFailure(message)
    }
}

func activeStateCommitsOnlyAfterDebounce() {
    var machine = MicActivityStateMachine()
    let settings = MicActivitySettings(activationDebounce: 0.2, deactivationGrace: 0.8)
    let start = Date(timeIntervalSinceReferenceDate: 10)

    expect(machine.ingest(.active, at: start, settings: settings).isEmpty, "active should debounce")
    expect(machine.phase == .pendingActive(since: start), "phase should be pending active")
    expect(machine.tick(at: start.addingTimeInterval(0.19), settings: settings).isEmpty, "early tick should not commit")

    let commits = machine.tick(at: start.addingTimeInterval(0.21), settings: settings)
    expectBecameActive(commits, "active commit mismatch")
    expect(machine.phase == .active(since: start), "phase should be active")
}

func shortInputSpikeIsCancelled() {
    var machine = MicActivityStateMachine()
    let settings = MicActivitySettings(activationDebounce: 0.2, deactivationGrace: 0.8)
    let start = Date(timeIntervalSinceReferenceDate: 20)

    _ = machine.ingest(.active, at: start, settings: settings)
    let commits = machine.ingest(.inactive, at: start.addingTimeInterval(0.08), settings: settings)

    expect(commits.isEmpty, "short spike should not commit")
    expect(machine.phase == .inactive, "short spike should cancel")
}

func inactiveStateCommitsOnlyAfterGracePeriod() {
    var machine = MicActivityStateMachine()
    let settings = MicActivitySettings(activationDebounce: 0, deactivationGrace: 0.9)
    let start = Date(timeIntervalSinceReferenceDate: 30)

    _ = machine.ingest(.active, at: start, settings: settings)
    expect(machine.phase == .active(since: start), "phase should be active immediately")

    expect(machine.ingest(.inactive, at: start.addingTimeInterval(1), settings: settings).isEmpty, "inactive should grace")
    expect(
        machine.phase == .pendingInactive(since: start.addingTimeInterval(1), activeSince: start),
        "phase should be pending inactive"
    )
    expect(machine.tick(at: start.addingTimeInterval(1.89), settings: settings).isEmpty, "early inactive tick should not commit")

    let commits = machine.tick(at: start.addingTimeInterval(1.91), settings: settings)
    expectBecameInactive(commits, "inactive commit mismatch")
    expect(machine.phase == .inactive, "phase should be inactive")
}

func runningDuringPendingInactiveKeepsActiveOwnership() {
    var machine = MicActivityStateMachine()
    let settings = MicActivitySettings(activationDebounce: 0, deactivationGrace: 0.9)
    let start = Date(timeIntervalSinceReferenceDate: 40)

    _ = machine.ingest(.active, at: start, settings: settings)
    _ = machine.ingest(.inactive, at: start.addingTimeInterval(1), settings: settings)

    let commits = machine.ingest(.active, at: start.addingTimeInterval(1.2), settings: settings)

    expect(commits.isEmpty, "return to active should not emit a new commit")
    expect(machine.phase == .active(since: start), "active ownership should be preserved")
}

activeStateCommitsOnlyAfterDebounce()
shortInputSpikeIsCancelled()
inactiveStateCommitsOnlyAfterGracePeriod()
runningDuringPendingInactiveKeepsActiveOwnership()
print("VopauseCore smoke tests passed")
