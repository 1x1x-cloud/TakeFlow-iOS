enum ServiceLifecycle: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case running
    case stopping
    case failed
}

protocol CancellableService: Sendable {
    func cancel() async
}
