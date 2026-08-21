#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    public import POSIX_Kernel_Process
#elseif os(Windows)
    public import Windows_Kernel_Process
#endif

extension Process {

    public enum Exit: Sendable {}
}

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

    extension Process.Exit {

        @inlinable
        public static func normal(_ status: Int32) -> Never {
            POSIX.Kernel.Process.Exit.normal(status)
        }

        @inlinable
        public static func now(_ status: Int32) -> Never {
            POSIX.Kernel.Process.Exit.now(status)
        }
    }

#elseif os(Windows)

    extension Process.Exit {

        @inlinable
        public static func now(_ status: Int32) -> Never {

            Windows.Kernel.Process.Exit.now(UInt32(bitPattern: status))
        }

        @inlinable
        public static func normal(_ status: Int32) -> Never {
            Windows.Kernel.Process.Exit.normal(status)
        }
    }

#endif

extension Process {

    @inlinable
    public static func exit(_ status: Int32) -> Never {
        Process.Exit.now(status)
    }
}
