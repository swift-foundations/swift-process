extension Process {

    public struct Output: Sendable, Equatable {

        public let status: Process.Status

        public let stdout: [UInt8]?

        public let stderr: [UInt8]?

        public init(
            status: Process.Status,
            stdout: [UInt8]? = nil,
            stderr: [UInt8]? = nil
        ) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }
}
