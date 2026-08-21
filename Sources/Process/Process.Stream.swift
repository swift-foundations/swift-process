extension Process {

    public enum Stream: Sendable, Equatable {

        case inherit

        case pipe
    }
}
