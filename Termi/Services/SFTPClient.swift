import Foundation
import CoreServices
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// SFTP protocol version 3 client (the version OpenSSH's sftp-server speaks), running over the
/// stdin/stdout of `ssh -s <host> sftp` — i.e. a multiplexed session on the master connection.
///
/// Requests are pipelined: transfers keep many READ/WRITE requests in flight, which is what
/// makes SFTP fast on high-latency links. File names are exchanged as raw bytes, so names with
/// spaces or newlines are handled correctly (unlike parsing `ls` output). Paths are kept as
/// `String`, which holds any valid UTF-8 unchanged; a name that is not valid UTF-8 cannot be
/// sent back as it came, so it is only listed (see `DirectoryEntry.rawName`).
final class SFTPClient: @unchecked Sendable {
    // MARK: Types

    struct Attributes: Sendable, Equatable {
        var size: UInt64?
        var uid: UInt32?
        var gid: UInt32?
        var permissions: UInt32?
        var accessTime: UInt32?
        var modificationTime: UInt32?

        enum FileType: Sendable, Equatable {
            case regular, directory, symlink, other
        }

        var fileType: FileType {
            guard let permissions else { return .other }
            switch permissions & 0o170000 {
            case 0o040000: return .directory
            case 0o120000: return .symlink
            case 0o100000: return .regular
            default: return .other
            }
        }

        var modificationDate: Date? {
            modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        /// The server said what this is, and it is not a regular file: a link, a folder, a pipe…
        /// No permissions, or no type bits in them (every attribute is optional in v3), leave the
        /// type unknown — which is not "special".
        var isKnownNonRegular: Bool {
            guard let permissions, permissions & 0o170000 != 0 else { return false }
            return permissions & 0o170000 != 0o100000
        }

        /// "rwxr-xr-x" style string for the permission bits (with type prefix).
        var permissionString: String {
            guard let permissions else { return "" }
            let type: Character = switch fileType {
            case .directory: "d"
            case .symlink: "l"
            case .regular: "-"
            case .other: "?"
            }
            let symbols: [Character] = ["r", "w", "x"]
            var result = String(type)
            for shift in stride(from: 6, through: 0, by: -3) {
                let bits = (permissions >> UInt32(shift)) & 0o7
                for (index, symbol) in symbols.enumerated() {
                    result.append(bits & (0o4 >> UInt32(index)) != 0 ? symbol : "-")
                }
            }
            return result
        }
    }

    struct DirectoryEntry: Sendable, Equatable {
        var name: String
        var longName: String
        var attributes: Attributes
        /// The name's bytes when they are not valid UTF-8. `name` is then a text for display
        /// only (U+FFFD where the bytes made no sense): a request built from it would address
        /// another file, or none.
        var rawName: Data? = nil

        var isNameRepresentable: Bool { rawName == nil }

        /// Owner / group names from the `ls -l` style long name, when the server provides one.
        var owner: String? { longNameField(2) }
        var group: String? { longNameField(3) }

        private func longNameField(_ index: Int) -> String? {
            let fields = longName.split(separator: " ", omittingEmptySubsequences: true)
            return fields.count > 8 ? String(fields[index]) : nil
        }
    }

    enum UploadDestination: Sendable {
        case absent
        case existing(Attributes)

        var attributes: Attributes? {
            if case .existing(let attributes) = self { return attributes }
            return nil
        }
    }

    /// How an existing remote file is replaced (see `upload`).
    enum ReplaceStrategy: Sendable, Equatable {
        /// Stage the whole file beside it, then publish it in one rename: a failed or cancelled
        /// upload leaves the original as it was, and the owner and mode are kept.
        case atomic
        /// Write into the file itself, truncated first: its inode, owner and mode stay. Only with
        /// the user's consent, where `.atomic` is blocked — an interrupted upload leaves the file
        /// cut short.
        case inPlace
    }

    /// Why an existing file cannot be replaced atomically. Always found before the original is
    /// touched; the staged copy is removed again.
    enum AtomicBlockReason: Sendable, Equatable {
        /// The server has no posix-rename@openssh.com (a v3 RENAME refuses an existing name).
        case noPosixRename
        /// No temporary file can be made next to it (its folder is not writable).
        case cannotCreateStage
        /// The copy cannot be given the original's owner (another account's file).
        case cannotPreserveOwner(uid: UInt32, gid: UInt32)
        /// The copy cannot be given the original's permissions.
        case cannotPreserveMode

        /// Why, as the end of a sentence ("… cannot be replaced safely: <this>").
        var explanation: String {
            switch self {
            case .noPosixRename:
                String(localized: "the server cannot replace a file in one step")
            case .cannotCreateStage:
                String(localized: "its folder is not writable, so no temporary copy can be made next to it")
            case .cannotPreserveOwner(let uid, let gid):
                // Without the format the locale writes grouped digits ("1,001"), which nothing
                // that matches on the number then finds.
                String(localized: "the new copy could not be given its owner (uid \(Int(uid), format: .number.grouping(.never)), gid \(Int(gid), format: .number.grouping(.never)))")
            case .cannotPreserveMode:
                String(localized: "the new copy could not be given its permissions")
            }
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case status(code: UInt32, message: String)
        case protocolViolation(String)
        case connectionClosed(String)
        /// The directory lists a name that is not valid UTF-8, so what is in it cannot be
        /// addressed exactly and an operation on the whole tree does not start there.
        case unrepresentableName(directory: String)
        /// The server lists more in one directory than any real one holds, or never finishes
        /// listing it. What was read so far is not handed out as if it were the whole directory.
        case listingTooLarge(directory: String, limit: Int)
        /// Below this folder the server describes directories nested without end.
        case treeTooDeep(path: String)
        case unsafeUploadTarget(String)
        case uploadTargetChanged(String)
        /// The file cannot be replaced atomically (why); nothing was changed.
        case atomicReplacementBlocked(path: String, reason: AtomicBlockReason)
        /// Something else took the place of the staged copy before it was published.
        case stagingFileReplaced(String)

        static let codeEOF: UInt32 = 1
        static let codeNoSuchFile: UInt32 = 2
        static let codePermissionDenied: UInt32 = 3
        static let codeUnsupported: UInt32 = 8

        var errorDescription: String? {
            switch self {
            case .status(let code, let message):
                switch code {
                case Self.codeNoSuchFile: return String(localized: "No such file or directory")
                case Self.codePermissionDenied: return String(localized: "Permission denied")
                case Self.codeUnsupported: return String(localized: "Operation not supported by the server")
                default: return message.isEmpty ? String(localized: "SFTP error \(code)") : message
                }
            case .protocolViolation(let message):
                return String(localized: "SFTP protocol error: \(message)")
            case .connectionClosed(let message):
                return message.isEmpty
                    ? String(localized: "The SFTP session was closed.")
                    : String(localized: "The SFTP session was closed: \(message)")
            case .unrepresentableName(let directory):
                return String(localized: "“\(directory)” contains a file name that is not valid UTF-8. It cannot be sent back to the server unchanged, so this folder was left as it is. Rename that file on the server first.")
            case .listingTooLarge(let directory, let limit):
                return String(localized: "The server lists more than \(limit) items in “\(directory)”, or never stops listing it. The operation was stopped.")
            case .treeTooDeep(let path):
                return String(localized: "The folders below “\(path)” are nested more than \(SFTPClient.maxTreeDepth) levels deep. The operation was stopped.")
            case .unsafeUploadTarget(let path):
                return String(localized: "“\(path)” is not a regular file. Upload to a regular file instead of replacing a link or special file.")
            case .uploadTargetChanged(let path):
                return String(localized: "“\(path)” changed during the upload. The remote file was left unchanged; upload again to review the conflict.")
            case .atomicReplacementBlocked(let path, let reason):
                return String(localized: "“\(path)” cannot be replaced safely: \(reason.explanation). Nothing was changed.")
            case .stagingFileReplaced(let path):
                return String(localized: "The temporary copy of “\(path)” was replaced on the server while it was uploaded. Nothing was replaced.")
            }
        }
    }

    private enum Response {
        case status(code: UInt32, message: String)
        case handle(Data)
        case data(Data)
        case name([DirectoryEntry])
        case attributes(Attributes)
        case extendedReply(Data)
    }

    private enum PacketType {
        static let initialize: UInt8 = 1
        static let version: UInt8 = 2
        static let open: UInt8 = 3
        static let close: UInt8 = 4
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let lstat: UInt8 = 7
        static let fstat: UInt8 = 8
        static let setstat: UInt8 = 9
        static let fsetstat: UInt8 = 10
        static let opendir: UInt8 = 11
        static let readdir: UInt8 = 12
        static let remove: UInt8 = 13
        static let mkdir: UInt8 = 14
        static let rmdir: UInt8 = 15
        static let realpath: UInt8 = 16
        static let stat: UInt8 = 17
        static let rename: UInt8 = 18
        static let readlink: UInt8 = 19
        static let symlink: UInt8 = 20
        static let extended: UInt8 = 200
        static let status: UInt8 = 101
        static let handle: UInt8 = 102
        static let data: UInt8 = 103
        static let name: UInt8 = 104
        static let attrs: UInt8 = 105
        static let extendedReply: UInt8 = 201
    }

    struct OpenFlags: OptionSet, Sendable {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x01)
        static let write = OpenFlags(rawValue: 0x02)
        static let append = OpenFlags(rawValue: 0x04)
        static let create = OpenFlags(rawValue: 0x08)
        static let truncate = OpenFlags(rawValue: 0x10)
        static let exclusive = OpenFlags(rawValue: 0x20)
    }

    static let chunkSize: UInt32 = 32 * 1024
    static let maxRequestsInFlight = 32
    private static let maxPacketLength = 4 * 1024 * 1024
    // What a server says a directory or a tree holds is bounded, far above anything real: a
    // hostile or broken one can list without end. Reaching a bound is an error, never a
    // shortened result — a partial listing would be deleted or downloaded as if it were whole.
    static let maxDirectoryEntries = 1_000_000
    private static let maxEmptyListingBatches = 64
    static let maxTreeDepth = 256

    // MARK: State

    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let errors: Pipe
    private let lock = NSLock()
    private let writeLock = NSLock()
    /// Write end of `input`, captured while it is open. `FileHandle.write(contentsOf:)` raises
    /// `NSFileHandleOperationException` — not a Swift error — when this end is closed on another
    /// thread (an upload's progress callback calls `close()` with writes still in flight).
    private let inputWriteFD: Int32
    private var inputWriteClosed = false
    private var nextRequestId: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Response, Error>] = [:]
    private var versionContinuation: CheckedContinuation<Void, Error>?
    private var closedError: Failure?
    private var stderrText = ""
    private(set) var extensions: Set<String> = []

    init(executable: String, arguments: [String], environment: [String: String]) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        input = Pipe()
        output = Pipe()
        errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        inputWriteFD = input.fileHandleForWriting.fileDescriptor
    }

    convenience init(command: SSHMasterConnection.Command) {
        self.init(executable: command.executable, arguments: command.arguments, environment: command.environment)
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        lock.withLock { closedError == nil }
    }

    // MARK: Lifecycle

    /// Start the subsystem and perform the INIT/VERSION handshake.
    func connect() async throws {
        try process.run()
        startReaders()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let failure: Failure? = lock.withLock {
                if let closedError { return closedError }
                versionContinuation = continuation
                return nil
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            var packet = SFTPWriter()
            packet.u8(PacketType.initialize)
            packet.u32(3)
            if let error = send(packet.data) {
                if let pendingVersion = lock.withLock({ () -> CheckedContinuation<Void, Error>? in
                    defer { versionContinuation = nil }
                    return versionContinuation
                }) {
                    pendingVersion.resume(throwing: error)
                }
            }
        }
    }

    /// End the session (closing stdin makes the multiplexed ssh session exit).
    func close() {
        let alreadyClosed: Bool = lock.withLock {
            if closedError != nil { return true }
            closedError = .connectionClosed("")
            return false
        }
        // Same lock as the packet write. Closing the handle on another thread used to raise
        // NSFileHandleOperationException out of FileHandle.write and kill the process.
        writeLock.withLock {
            guard !inputWriteClosed else { return }
            inputWriteClosed = true
            try? input.fileHandleForWriting.close()
        }
        if !alreadyClosed {
            failAll(with: .connectionClosed(""))
        }
        let process = self.process
        if process.isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                SSHRuntime.stop(process, grace: 2)
            }
        }
    }

    private func startReaders() {
        let stdout = output.fileHandleForReading
        let thread = Thread { [weak self] in
            var buffer = Data()
            var start = 0
            while true {
                let chunk = stdout.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.connectionEnded()
                    return
                }
                buffer.append(chunk)
                while buffer.count - start >= 4 {
                    let length = buffer.withUnsafeBytes { raw -> Int in
                        let base = raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self)
                        return Int(base[0]) << 24 | Int(base[1]) << 16 | Int(base[2]) << 8 | Int(base[3])
                    }
                    guard length > 0, length <= Self.maxPacketLength else {
                        self.failAll(with: .protocolViolation("invalid packet length \(length)"))
                        return
                    }
                    guard buffer.count - start >= 4 + length else { break }
                    let lower = buffer.startIndex + start + 4
                    let packet = buffer.subdata(in: lower..<(lower + length))
                    start += 4 + length
                    self.handle(packet)
                }
                if start > 1 << 20 || start == buffer.count {
                    buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + start))
                    start = 0
                }
            }
        }
        thread.name = "SFTP reader"
        thread.start()

        let stderr = errors.fileHandleForReading
        let errorThread = Thread { [weak self] in
            while true {
                let chunk = stderr.availableData
                if chunk.isEmpty { return }
                guard let self else { return }
                let text = String(decoding: chunk, as: UTF8.self)
                self.lock.withLock {
                    self.stderrText = String((self.stderrText + text).suffix(4096))
                }
            }
        }
        errorThread.name = "SFTP stderr"
        errorThread.start()
    }

    private func connectionEnded() {
        // Give stderr a moment so the error explains why (e.g. "subsystem request failed").
        Thread.sleep(forTimeInterval: 0.1)
        let message = lock.withLock {
            SSHMasterConnection.informationalOutput(stderrText)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        }
        failAll(with: .connectionClosed(message))
    }

    private func failAll(with failure: Failure) {
        let (continuations, version): ([CheckedContinuation<Response, Error>], CheckedContinuation<Void, Error>?) = lock.withLock {
            if closedError == nil || closedError == .connectionClosed("") {
                closedError = failure
            }
            let continuations = Array(pending.values)
            pending.removeAll()
            let version = versionContinuation
            versionContinuation = nil
            return (continuations, version)
        }
        continuations.forEach { $0.resume(throwing: failure) }
        version?.resume(throwing: failure)
    }

    // MARK: Packet I/O

    /// Write one framed packet. Returns the failure if the pipe is closed.
    private func send(_ payload: Data) -> Failure? {
        var frame = Data(capacity: payload.count + 4)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let code: Int32 = writeLock.withLock {
            if inputWriteClosed { return EPIPE }
            return Self.writeAll(inputWriteFD, frame)
        }
        guard code == 0 else {
            let failure = Failure.connectionClosed(String(cString: strerror(code)))
            failAll(with: failure)
            return failure
        }
        return nil
    }

    /// Blocking write. `EINTR` is retried. A closed read end is `EPIPE` (SIGPIPE is held for
    /// this call only, so it does not kill the process) and a closed write end is `EBADF`.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32 {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) != 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        let failed: Int32 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return 0 }
            var offset = 0
            while offset < raw.count {
                let n = systemWrite(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                return code == 0 ? EIO : code
            }
            return 0
        }
        var pending = sigset_t()
        sigpending(&pending)
        if sigismember(&pending, SIGPIPE) == 1 {
            var caught: Int32 = 0
            sigwait(&blocked, &caught)
        }
        pthread_sigmask(SIG_SETMASK, &previous, nil)
        return failed
    }

    private static func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #else
        Darwin.write(fd, buffer, count)
        #endif
    }

    private func handle(_ packet: Data) {
        var reader = SFTPReader(packet)
        do {
            let type = try reader.u8()
            if type == PacketType.version {
                _ = try reader.u32()
                var names = Set<String>()
                while !reader.isAtEnd {
                    names.insert(try reader.string())
                    _ = try reader.bytes()
                }
                let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                    extensions = names
                    defer { versionContinuation = nil }
                    return versionContinuation
                }
                continuation?.resume()
                return
            }

            let id = try reader.u32()
            let response: Response
            switch type {
            case PacketType.status:
                let code = try reader.u32()
                let message = reader.isAtEnd ? "" : try reader.string()
                response = .status(code: code, message: message)
            case PacketType.handle:
                response = .handle(try reader.bytes())
            case PacketType.data:
                response = .data(try reader.bytes())
            case PacketType.name:
                let count = try reader.u32()
                var entries: [DirectoryEntry] = []
                entries.reserveCapacity(Int(min(count, 10_000)))
                for _ in 0..<count {
                    let name = try reader.exactString()
                    let longName = try reader.string()
                    let attributes = try reader.attributes()
                    entries.append(DirectoryEntry(name: name.text, longName: longName, attributes: attributes,
                                                  rawName: name.rawBytes))
                }
                response = .name(entries)
            case PacketType.attrs:
                response = .attributes(try reader.attributes())
            case PacketType.extendedReply:
                response = .extendedReply(reader.remaining())
            default:
                throw Failure.protocolViolation("unexpected packet type \(type)")
            }
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            continuation?.resume(returning: response)
        } catch let failure as Failure {
            failAll(with: failure)
        } catch {
            failAll(with: .protocolViolation("\(error)"))
        }
    }

    private func request(_ type: UInt8, cancellable: Bool = true,
                         _ body: (inout SFTPWriter) -> Void) async throws -> Response {
        if cancellable { try Task.checkCancellation() }
        var packet = SFTPWriter()
        packet.u8(type)
        let id: UInt32 = lock.withLock {
            defer { nextRequestId &+= 1 }
            return nextRequestId
        }
        packet.u32(id)
        body(&packet)
        let payload = packet.data
        return try await withCheckedThrowingContinuation { continuation in
            let failure: Failure? = lock.withLock {
                if let closedError { return closedError }
                pending[id] = continuation
                return nil
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            if let failure = send(payload),
               let stillPending = lock.withLock({ pending.removeValue(forKey: id) }) {
                stillPending.resume(throwing: failure)
            }
        }
    }

    private func expectStatusOK(_ response: Response) throws {
        guard case .status(let code, let message) = response else {
            throw Failure.protocolViolation("expected status")
        }
        guard code == 0 else { throw Failure.status(code: code, message: message) }
    }

    private func expectHandle(_ response: Response) throws -> Data {
        switch response {
        case .handle(let handle): return handle
        case .status(let code, let message): throw Failure.status(code: code, message: message)
        default: throw Failure.protocolViolation("expected handle")
        }
    }

    private func expectAttributes(_ response: Response) throws -> Attributes {
        switch response {
        case .attributes(let attributes): return attributes
        case .status(let code, let message): throw Failure.status(code: code, message: message)
        default: throw Failure.protocolViolation("expected attributes")
        }
    }

    // MARK: Metadata operations

    /// Canonical absolute path ("." → home directory). The answer becomes the directory every
    /// later path is built on, so one that is not an absolute path (empty, "docs", "../x") or
    /// that cannot be sent back as it came is refused.
    func realPath(_ path: String) async throws -> String {
        let response = try await request(PacketType.realpath) { $0.string(path) }
        switch response {
        case .name(let entries) where !entries.isEmpty:
            let resolved = try Self.representableName(entries[0])
            guard resolved.utf8.first == 0x2F, !resolved.utf8.contains(0) else {
                throw Failure.protocolViolation("the server did not answer with an absolute path")
            }
            return resolved
        case .status(let code, let message): throw Failure.status(code: code, message: message)
        default: throw Failure.protocolViolation("expected name")
        }
    }

    /// The name of a REALPATH / READLINK answer, unless its bytes are not valid UTF-8.
    private static func representableName(_ entry: DirectoryEntry) throws -> String {
        guard entry.isNameRepresentable else {
            throw Failure.protocolViolation("the server answered with a path that is not valid UTF-8")
        }
        return entry.name
    }

    func stat(_ path: String) async throws -> Attributes {
        try expectAttributes(try await request(PacketType.stat) { $0.string(path) })
    }

    func lstat(_ path: String) async throws -> Attributes {
        try expectAttributes(try await request(PacketType.lstat) { $0.string(path) })
    }

    /// Whether `name` can be one entry of a directory. A server that lists anything else — a
    /// name with a path separator ("a/b", "../x"), an empty name, "." or "..", a NUL — is
    /// hostile or broken: joined to the directory it would address another file, so a folder
    /// download could write outside the folder the user picked and a recursive delete could
    /// remove something outside the tree. (OpenSSH's sftp skips such entries as well.)
    ///
    /// Judged on the UTF-8 bytes, as the server and the local file system do. `String` compares
    /// whole characters: "/" followed by a combining mark is one character that is not "/", so
    /// "../" + U+0301 + "x" would pass a character-wise check and still leave the directory.
    static func isValidEntryName(_ name: String) -> Bool {
        let bytes = name.utf8
        return !bytes.isEmpty && !bytes.elementsEqual(".".utf8) && !bytes.elementsEqual("..".utf8)
            && !bytes.contains(0x2F) && !bytes.contains(0x00)
    }

    /// Directory listing without "." and "..", and without entries whose name is not a file
    /// name (see `isValidEntryName`): every caller composes paths from these names. An entry
    /// whose name is not valid UTF-8 stays in the listing, marked (`isNameRepresentable`), so
    /// that callers see the directory is not empty; no path may be composed from its name.
    ///
    /// Throws `listingTooLarge` after `maxEntries` entries, or when the server keeps answering
    /// without listing anything and without ending the listing.
    func listDirectory(_ path: String, maxEntries: Int = SFTPClient.maxDirectoryEntries) async throws -> [DirectoryEntry] {
        let handle = try expectHandle(try await request(PacketType.opendir) { $0.string(path) })
        var entries: [DirectoryEntry] = []
        // Counted as received, before any name is dropped: the bound is on what the server sends.
        var received = 0
        var emptyBatches = 0
        do {
            readLoop: while true {
                let response = try await request(PacketType.readdir) { $0.bytes(handle) }
                switch response {
                case .name(let batch):
                    received += batch.count
                    if batch.isEmpty { emptyBatches += 1 }
                    guard received <= maxEntries, emptyBatches <= Self.maxEmptyListingBatches else {
                        throw Failure.listingTooLarge(directory: path, limit: maxEntries)
                    }
                    entries.append(contentsOf: batch.filter { Self.isValidEntryName($0.name) })
                case .status(let code, let message):
                    if code == Failure.codeEOF { break readLoop }
                    throw Failure.status(code: code, message: message)
                default:
                    throw Failure.protocolViolation("expected name")
                }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
        return entries
    }

    func makeDirectory(_ path: String, permissions: UInt32? = nil) async throws {
        try expectStatusOK(try await request(PacketType.mkdir) {
            $0.string(path)
            $0.attributes(Attributes(permissions: permissions))
        })
    }

    func removeDirectory(_ path: String) async throws {
        try expectStatusOK(try await request(PacketType.rmdir) { $0.string(path) })
    }

    func removeFile(_ path: String) async throws {
        try expectStatusOK(try await request(PacketType.remove) { $0.string(path) })
    }

    /// Rename; replaces an existing target when the server supports posix-rename (OpenSSH does).
    /// Whether something is at `destination` is for the caller to find out first (see
    /// `SFTPSession.rename`): which of the two requests is sent depends on the server.
    func rename(_ source: String, to destination: String) async throws {
        if extensions.contains("posix-rename@openssh.com") {
            try expectStatusOK(try await request(PacketType.extended) {
                $0.string("posix-rename@openssh.com")
                $0.string(source)
                $0.string(destination)
            })
        } else {
            try expectStatusOK(try await request(PacketType.rename) {
                $0.string(source)
                $0.string(destination)
            })
        }
    }

    func setPermissions(_ path: String, _ permissions: UInt32) async throws {
        try expectStatusOK(try await request(PacketType.setstat) {
            $0.string(path)
            $0.attributes(Attributes(permissions: permissions & 0o7777))
        })
    }

    func readLink(_ path: String) async throws -> String {
        let response = try await request(PacketType.readlink) { $0.string(path) }
        switch response {
        case .name(let entries) where !entries.isEmpty: return try Self.representableName(entries[0])
        case .status(let code, let message): throw Failure.status(code: code, message: message)
        default: throw Failure.protocolViolation("expected name")
        }
    }

    /// Remove a file, symlink or whole directory tree. A directory that lists a name which is
    /// not valid UTF-8 is not touched: that entry cannot be removed (its exact name cannot be
    /// sent), so the directory could not go either, and the request would hit another name.
    /// A tree deeper than `maxTreeDepth` stops with an error (what was reached before is gone).
    func removeRecursively(_ path: String) async throws {
        try await removeRecursively(path, root: path, depth: 0)
    }

    private func removeRecursively(_ path: String, root: String, depth: Int) async throws {
        let attributes = try await lstat(path)
        guard attributes.fileType == .directory else {
            try await removeFile(path)
            return
        }
        guard depth < Self.maxTreeDepth else { throw Failure.treeTooDeep(path: root) }
        let entries = try await listDirectory(path)
        guard entries.allSatisfy(\.isNameRepresentable) else {
            throw Failure.unrepresentableName(directory: path)
        }
        for entry in entries {
            try Task.checkCancellation()
            let child = Self.join(path, entry.name)
            if entry.attributes.fileType == .directory {
                try await removeRecursively(child, root: root, depth: depth + 1)
            } else {
                try await removeFile(child)
            }
        }
        try await removeDirectory(path)
    }

    // MARK: File handles

    private func openFile(_ path: String, flags: OpenFlags, permissions: UInt32? = nil,
                          cancellable: Bool = true) async throws -> Data {
        try expectHandle(try await request(PacketType.open, cancellable: cancellable) {
            $0.string(path)
            $0.u32(flags.rawValue)
            $0.attributes(Attributes(permissions: permissions))
        })
    }

    private func closeHandle(_ handle: Data) async throws {
        // Sent even from a cancelled task: cleaning up after a cancelled transfer is exactly
        // when the server-side handle must still be released.
        try expectStatusOK(try await request(PacketType.close, cancellable: false) { $0.bytes(handle) })
    }

    /// READ; returns nil at end of file.
    private func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        let response = try await request(PacketType.read) {
            $0.bytes(handle)
            $0.u64(offset)
            $0.u32(length)
        }
        switch response {
        case .data(let data): return data
        case .status(let code, let message):
            if code == Failure.codeEOF { return nil }
            throw Failure.status(code: code, message: message)
        default: throw Failure.protocolViolation("expected data")
        }
    }

    private func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        try expectStatusOK(try await request(PacketType.write) {
            $0.bytes(handle)
            $0.u64(offset)
            $0.bytes(data)
        })
    }

    // MARK: Transfers

    /// Moves a local file to the Trash, where it can be put back. Returns where it is now.
    static let moveToTrash: @Sendable (URL) throws -> URL = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        // Without the new location the old one still carries the file's name.
        return (trashed as URL?) ?? url
    }

    /// Marks a file as downloaded, as a browser does (the quarantine attribute): its content
    /// and its name came from a server, and opening it — from this app's local panel or from
    /// Finder — then goes through the system's checks for downloaded files instead of running
    /// a script or following a location file at a double-click. A volume that cannot hold the
    /// attribute leaves the file as it is; that is no reason to fail a transfer.
    static func markAsDownloaded(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Termi"
        ]
        try? url.setResourceValues(values)
    }

    /// Download a file with pipelined reads. `progress` receives the bytes written so far.
    /// The data goes to a temporary file next to `localURL` that takes its place only once the
    /// download is complete, so an existing local file survives a failed or cancelled download.
    /// It is then not overwritten either: `trash` moves it to the Trash, where it can be put back
    /// (when that fails, the download fails and the file stays).
    @discardableResult
    func download(_ remotePath: String, to localURL: URL,
                  progress: @escaping @Sendable (UInt64) -> Void = { _ in },
                  trash: @Sendable (URL) throws -> URL = SFTPClient.moveToTrash) async throws -> UInt64 {
        let fm = FileManager.default
        // Never put a file where a local folder is: replacing it would delete the whole tree.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: localURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: localURL.path])
        }

        let handle = try await openFile(remotePath, flags: .read)
        let knownSize = (try? expectAttributes(try await request(PacketType.fstat) { $0.bytes(handle) }))?.size

        // Named after the file, unless that would exceed the 255-byte limit on file names.
        let partSuffix = ".\(UUID().uuidString.prefix(8)).part"
        let name = localURL.lastPathComponent
        let partName = name.utf8.count + partSuffix.utf8.count < 255 ? "." + name + partSuffix : partSuffix
        let partURL = localURL.deletingLastPathComponent().appendingPathComponent(partName)
        let file: FileHandle
        do {
            guard fm.createFile(atPath: partURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: localURL.path])
            }
            file = try FileHandle(forWritingTo: partURL)
        } catch {
            try? fm.removeItem(at: partURL)
            try? await closeHandle(handle)
            throw error
        }
        var received: UInt64 = 0

        do {
            try await withThrowingTaskGroup(of: (offset: UInt64, requested: UInt32, data: Data?).self) { group in
                var nextOffset: UInt64 = 0
                var reachedEnd = false
                var inFlight = 0

                func schedule(offset: UInt64, length: UInt32) {
                    inFlight += 1
                    group.addTask {
                        (offset, length, try await self.read(handle, offset: offset, length: length))
                    }
                }
                func scheduleNext() {
                    guard !reachedEnd else { return }
                    // The size the server reports only says how far to read ahead. Past it, one
                    // request at a time goes on until the server says the file has ended: files
                    // in /proc and /sys report 0, and one that grew since is longer than it
                    // said. Stopping at the reported size would call a cut-off copy complete.
                    if let knownSize, nextOffset >= knownSize, inFlight > 0 { return }
                    schedule(offset: nextOffset, length: Self.chunkSize)
                    nextOffset += UInt64(Self.chunkSize)
                }

                for _ in 0..<Self.maxRequestsInFlight { scheduleNext() }
                while inFlight > 0, let result = try await group.next() {
                    inFlight -= 1
                    try Task.checkCancellation()
                    guard let data = result.data, !data.isEmpty else {
                        reachedEnd = true
                        continue
                    }
                    try file.seek(toOffset: result.offset)
                    try file.write(contentsOf: data)
                    received += UInt64(data.count)
                    progress(received)
                    if data.count < Int(result.requested) {
                        // Short read: fetch the rest of this chunk before moving on.
                        schedule(offset: result.offset + UInt64(data.count),
                                 length: result.requested - UInt32(data.count))
                    }
                    scheduleNext()
                }
            }
            try file.close()
            try await closeHandle(handle)
        } catch {
            try? file.close()
            try? fm.removeItem(at: partURL)
            try? await closeHandle(handle)
            throw error
        }
        // Before it gets its name: the file is never there under it without the mark.
        Self.markAsDownloaded(partURL)
        do {
            // attributesOfItem does not follow links: a link at `localURL` counts as a file.
            // A folder that appeared there meanwhile is left alone (the rename below fails).
            if let existing = try? fm.attributesOfItem(atPath: localURL.path),
               existing[.type] as? FileAttributeType != .typeDirectory {
                do {
                    _ = try trash(localURL)
                } catch let error as CocoaError where error.code == .featureUnsupported {
                    // The volume has no Trash (network shares): Finder could only delete there
                    // too, so the file is replaced in place as before.
                }
            }
            try replaceFile(at: localURL, with: partURL)
        } catch {
            try? fm.removeItem(at: partURL)
            throw error
        }
        return received
    }

    /// Upload a local file with pipelined writes.
    ///
    /// - A new file is created under its own name with an exclusive OPEN (something that
    ///   appeared there since is never replaced), with the local file's mode for the server's
    ///   umask or default ACL to limit — as OpenSSH's sftp, FileZilla and Cyberduck do. Nothing
    ///   is asked of the server afterwards (no SETSTAT, no REMOVE, no reported permissions), so
    ///   any v3 server takes it. Only a failed or cancelled upload removes what it created.
    /// - An existing file is replaced only with the caller's consent. `.atomic` stages the whole
    ///   file beside it and publishes it in one rename, keeping owner and mode; where that cannot
    ///   be done it fails with `atomicReplacementBlocked` before the original is touched, and the
    ///   caller may ask the user about `.inPlace`.
    ///
    /// Links, folders and special files are refused: they are neither replaced nor written
    /// through. A server that reports no file type is not taken for one of them.
    @discardableResult
    func upload(_ localURL: URL, to remotePath: String, permissions: UInt32? = nil,
                expectation: UploadDestination? = nil, strategy: ReplaceStrategy = .atomic,
                progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> UInt64 {
        try Task.checkCancellation()
        let original = try await uploadAttributes(at: remotePath)
        if let expectation {
            guard Self.isUnchanged(original, since: expectation.attributes) else {
                throw Failure.uploadTargetChanged(remotePath)
            }
        }
        if let original {
            guard !original.isKnownNonRegular else { throw Failure.unsafeUploadTarget(remotePath) }
            if strategy == .atomic, !extensions.contains("posix-rename@openssh.com") {
                throw Failure.atomicReplacementBlocked(path: remotePath, reason: .noPosixRename)
            }
        }
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        guard let original else {
            return try await createNew(remotePath, from: file, permissions: permissions, progress: progress)
        }
        switch strategy {
        case .atomic:
            return try await replaceAtomically(remotePath, original: original, localPermissions: permissions,
                                               from: file, progress: progress)
        case .inPlace:
            return try await overwriteInPlace(remotePath, original: original, from: file, progress: progress)
        }
    }

    /// Called with the staging path right after its handle is closed (tests only: a stand-in for
    /// someone who may write the folder and swaps the file for a link at that moment).
    var afterStageClose: (@Sendable (String) -> Void)?

    private func createNew(_ remotePath: String, from file: FileHandle, permissions: UInt32?,
                           progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        // Wait for the OPEN response even after cancellation, so that its handle can be closed.
        let handle: Data
        do {
            handle = try await openFile(remotePath, flags: [.write, .create, .exclusive],
                                        permissions: (permissions ?? 0o600) & 0o777, cancellable: false)
        } catch Failure.status(let code, let message)
                    where code != Failure.codePermissionDenied && code != Failure.codeNoSuchFile {
            // OpenSSH answers an exclusive OPEN of a name that exists with a plain FAILURE.
            if (try? await uploadAttributes(at: remotePath)) != nil { throw Failure.uploadTargetChanged(remotePath) }
            throw Failure.status(code: code, message: message)
        }
        var handleNeedsClose = true
        do {
            let sent = try await writeAll(file, to: handle, progress: progress)
            handleNeedsClose = false
            try await closeHandle(handle)
            return sent
        } catch {
            if handleNeedsClose { try? await closeHandle(handle) }
            // Only what this call's exclusive OPEN created.
            _ = try? await request(PacketType.remove, cancellable: false) { $0.string(remotePath) }
            throw error
        }
    }

    private func replaceAtomically(_ remotePath: String, original: Attributes, localPermissions: UInt32?,
                                   from file: FileHandle,
                                   progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let mode = original.permissions.map { $0 & 0o7777 }
        let temporaryPath = Self.join(Self.parent(of: remotePath), ".termi-upload-\(UUID().uuidString).part")
        // Exclusive creation: no other entry is ever written. Created with the original's mode,
        // so that for an ordinary 0644 / 0755 file under the usual umask nothing needs changing
        // afterwards (servers that refuse SETSTAT take it); where the server did not say, with
        // the local file's, as a new file. Wait for the OPEN response even after cancellation so
        // its handle can be closed.
        let handle: Data
        do {
            handle = try await openFile(temporaryPath, flags: [.write, .create, .exclusive],
                                        permissions: (mode ?? localPermissions ?? 0o600) & 0o777, cancellable: false)
        } catch Failure.status(let code, _) where code == Failure.codePermissionDenied {
            throw Failure.atomicReplacementBlocked(path: remotePath, reason: .cannotCreateStage)
        }
        var handleNeedsClose = true
        var stageExists = true
        do {
            let sent = try await writeAll(file, to: handle, progress: progress)
            // Owner and mode go onto the open handle (fchown / fchmod on the server): anyone who
            // may write the folder can swap a path for a link, never a handle.
            try await preserveOwnerAndMode(of: original, on: handle, stagePath: temporaryPath, remotePath: remotePath)
            // CLOSE may allow the server to reuse this handle for another concurrent
            // transfer. Never send it again, even when publication fails afterward.
            handleNeedsClose = false
            try await closeHandle(handle)
            afterStageClose?(temporaryPath)
            try Task.checkCancellation()
            // What has the staging name now must still be the file just written.
            let staged = try await lstat(temporaryPath)
            guard !staged.isKnownNonRegular,
                  mode == nil || staged.permissions == nil || staged.permissions.map({ $0 & 0o7777 }) == mode,
                  original.uid == nil || staged.uid == nil || staged.uid == original.uid,
                  original.gid == nil || staged.gid == nil || staged.gid == original.gid else {
                throw Failure.stagingFileReplaced(remotePath)
            }
            let current = try await uploadAttributes(at: remotePath)
            guard Self.isUnchanged(current, since: original) else { throw Failure.uploadTargetChanged(remotePath) }
            try Task.checkCancellation()
            try await rename(temporaryPath, to: remotePath)
            stageExists = false
            return sent
        } catch {
            if handleNeedsClose { try? await closeHandle(handle) }
            // A cancelled task must still clean up its own temporary file, never the original.
            // (REMOVE does not follow links: a link put in its place is what goes.)
            if stageExists {
                _ = try? await request(PacketType.remove, cancellable: false) { $0.string(temporaryPath) }
            }
            throw error
        }
    }

    /// Give the staged file the original's owner and mode, on its open handle, and check what the
    /// server kept. Only what differs is changed: chown before chmod, which chown can clear
    /// setuid / setgid from. What the server did not report about the original is left alone.
    private func preserveOwnerAndMode(of original: Attributes, on handle: Data, stagePath: String,
                                      remotePath: String) async throws {
        var staged = try await handleAttributes(handle)
        if let uid = original.uid, let gid = original.gid, uid != staged.uid || gid != staged.gid {
            guard try await setAttributes(Attributes(uid: uid, gid: gid), handle: handle, path: stagePath) else {
                throw Failure.atomicReplacementBlocked(path: remotePath, reason: .cannotPreserveOwner(uid: uid, gid: gid))
            }
            staged = try await handleAttributes(handle)
            if let stagedUid = staged.uid, let stagedGid = staged.gid, stagedUid != uid || stagedGid != gid {
                throw Failure.atomicReplacementBlocked(path: remotePath, reason: .cannotPreserveOwner(uid: uid, gid: gid))
            }
        }
        if let mode = original.permissions.map({ $0 & 0o7777 }), staged.permissions.map({ $0 & 0o7777 }) != mode {
            guard try await setAttributes(Attributes(permissions: mode), handle: handle, path: stagePath) else {
                throw Failure.atomicReplacementBlocked(path: remotePath, reason: .cannotPreserveMode)
            }
            staged = try await handleAttributes(handle)
            if let kept = staged.permissions.map({ $0 & 0o7777 }), kept != mode {
                throw Failure.atomicReplacementBlocked(path: remotePath, reason: .cannotPreserveMode)
            }
        }
    }

    private func handleAttributes(_ handle: Data) async throws -> Attributes {
        try expectAttributes(try await request(PacketType.fstat) { $0.bytes(handle) })
    }

    /// FSETSTAT on an open handle. A server without it may offer lsetstat@openssh.com, which
    /// does not follow links (it fails on one). False when the server refused.
    private func setAttributes(_ attributes: Attributes, handle: Data, path: String) async throws -> Bool {
        let response = try await request(PacketType.fsetstat) {
            $0.bytes(handle)
            $0.attributes(attributes)
        }
        guard case .status(let code, _) = response else { throw Failure.protocolViolation("expected status") }
        if code == 0 { return true }
        guard code == Failure.codeUnsupported, attributes.size == nil,
              extensions.contains("lsetstat@openssh.com") else { return false }
        let fallback = try await request(PacketType.extended) {
            $0.string("lsetstat@openssh.com")
            $0.string(path)
            $0.attributes(attributes)
        }
        guard case .status(let fallbackCode, _) = fallback else { throw Failure.protocolViolation("expected status") }
        return fallbackCode == 0
    }

    /// Write into the existing file itself: its inode, owner and mode stay as they are. Only
    /// after the user agreed (an interrupted upload leaves the file cut short).
    private func overwriteInPlace(_ remotePath: String, original: Attributes, from file: FileHandle,
                                  progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        // No .create: a file deleted meanwhile is not made again. No .truncate yet: first make
        // sure the handle is the file the user agreed to overwrite — a name can be swapped for a
        // link between LSTAT and OPEN, a handle cannot.
        var handle = try await openFile(remotePath, flags: [.write], cancellable: false)
        var handleNeedsClose = true
        do {
            guard Self.isUnchanged(try await handleAttributes(handle), since: original) else {
                throw Failure.uploadTargetChanged(remotePath)
            }
            try Task.checkCancellation()
            if try await !setAttributes(Attributes(size: 0), handle: handle, path: remotePath) {
                // The server does not truncate through a handle: open it again truncating, and
                // check once more that it is still the same file.
                handleNeedsClose = false
                try await closeHandle(handle)
                handle = try await openFile(remotePath, flags: [.write, .truncate], cancellable: false)
                handleNeedsClose = true
                var reopened = try await handleAttributes(handle)
                reopened.size = original.size
                reopened.modificationTime = original.modificationTime
                guard Self.isUnchanged(reopened, since: original) else { throw Failure.uploadTargetChanged(remotePath) }
            }
            let sent = try await writeAll(file, to: handle, progress: progress)
            handleNeedsClose = false
            try await closeHandle(handle)
            return sent
        } catch {
            if handleNeedsClose { try? await closeHandle(handle) }
            throw error
        }
    }

    /// Write the whole local file into `handle`, many requests in flight. Returns the bytes sent.
    private func writeAll(_ file: FileHandle, to handle: Data,
                          progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        var sent: UInt64 = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            var offset: UInt64 = 0
            var inFlight = 0
            var endOfFile = false

            func fill() throws {
                while !endOfFile && inFlight < Self.maxRequestsInFlight {
                    guard let chunk = try file.read(upToCount: Int(Self.chunkSize)), !chunk.isEmpty else {
                        endOfFile = true
                        return
                    }
                    let chunkOffset = offset
                    offset += UInt64(chunk.count)
                    inFlight += 1
                    group.addTask {
                        try await self.write(handle, offset: chunkOffset, data: chunk)
                        return chunk.count
                    }
                }
            }

            try fill()
            while inFlight > 0, let written = try await group.next() {
                inFlight -= 1
                try Task.checkCancellation()
                sent += UInt64(written)
                progress(sent)
                try fill()
            }
        }
        return sent
    }

    /// Whether what the server says about a path now is what it said before (the access time
    /// aside: reading a file changes it). Attributes one answer leaves out are not compared.
    static func isUnchanged(_ current: Attributes?, since expected: Attributes?) -> Bool {
        guard let current, let expected else { return current == nil && expected == nil }
        func same<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a == nil || b == nil || a == b }
        return same(current.size, expected.size) && same(current.uid, expected.uid)
            && same(current.gid, expected.gid) && same(current.permissions, expected.permissions)
            && same(current.modificationTime, expected.modificationTime)
    }

    func uploadAttributes(at path: String) async throws -> Attributes? {
        do { return try await lstat(path) }
        catch Failure.status(let code, _) where code == Failure.codeNoSuchFile { return nil }
    }

    /// Read a whole (small) remote file into memory.
    func readFile(_ path: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        let handle = try await openFile(path, flags: .read)
        var result = Data()
        do {
            while result.count < maxBytes {
                guard let chunk = try await read(handle, offset: UInt64(result.count), length: Self.chunkSize) else { break }
                result.append(chunk)
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
        return result
    }

    // MARK: Paths

    // Both look for "/" in the UTF-8 bytes and never normalise: character-wise, the "/" before
    // a name that starts with a combining mark is part of that name's first character and is
    // not found, and a path that is not byte for byte what the server listed is another file.

    static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return name }
        return directory.utf8.last == 0x2F ? directory + name : directory + "/" + name
    }

    /// The last component of a path, as its bytes say.
    static func name(of path: String) -> String {
        var bytes = path.utf8[...]
        if bytes.count > 1, bytes.last == 0x2F { bytes = bytes.dropLast() }
        guard let slash = bytes.lastIndex(of: 0x2F) else { return String(Substring(bytes)) }
        return String(Substring(bytes[bytes.index(after: slash)...]))
    }

    static func parent(of path: String) -> String {
        var bytes = path.utf8[...]
        guard !bytes.elementsEqual("/".utf8) else { return "/" }
        if bytes.last == 0x2F { bytes = bytes.dropLast() }
        guard let slash = bytes.lastIndex(of: 0x2F) else { return "." }
        return slash == bytes.startIndex ? "/" : String(Substring(bytes[..<slash]))
    }
}

/// rename(2): atomically puts `source` in place of `destination`; it fails rather than replace a
/// directory. At file scope because inside `SFTPClient`, `rename` is the remote rename.
private func replaceFile(at destination: URL, with source: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

// MARK: - Wire encoding

struct SFTPWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) {
        bytes(Data(value.utf8))
    }

    mutating func attributes(_ attributes: SFTPClient.Attributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= 0x1 }
        if attributes.uid != nil && attributes.gid != nil { flags |= 0x2 }
        if attributes.permissions != nil { flags |= 0x4 }
        if attributes.accessTime != nil && attributes.modificationTime != nil { flags |= 0x8 }
        u32(flags)
        if let size = attributes.size { u64(size) }
        if let uid = attributes.uid, let gid = attributes.gid {
            u32(uid)
            u32(gid)
        }
        if let permissions = attributes.permissions { u32(permissions) }
        if let atime = attributes.accessTime, let mtime = attributes.modificationTime {
            u32(atime)
            u32(mtime)
        }
    }
}

struct SFTPReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else {
            throw SFTPClient.Failure.protocolViolation("truncated packet")
        }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func u8() throws -> UInt8 {
        try take(1).first!
    }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try take(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytes() throws -> Data {
        let length = Int(try u32())
        return Data(try take(length))
    }

    /// Text for display and messages: bytes that are not valid UTF-8 become U+FFFD.
    mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    /// A file name or path. `rawBytes` is nil when `text` encodes back to exactly the bytes
    /// received; otherwise it holds them, and `text` must not be used to address the file.
    mutating func exactString() throws -> (text: String, rawBytes: Data?) {
        let raw = try bytes()
        let text = String(decoding: raw, as: UTF8.self)
        return (text, text.utf8.elementsEqual(raw) ? nil : raw)
    }

    mutating func remaining() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }

    mutating func attributes() throws -> SFTPClient.Attributes {
        let flags = try u32()
        var attributes = SFTPClient.Attributes()
        if flags & 0x1 != 0 { attributes.size = try u64() }
        if flags & 0x2 != 0 {
            attributes.uid = try u32()
            attributes.gid = try u32()
        }
        if flags & 0x4 != 0 { attributes.permissions = try u32() }
        if flags & 0x8 != 0 {
            attributes.accessTime = try u32()
            attributes.modificationTime = try u32()
        }
        if flags & 0x8000_0000 != 0 {
            let count = try u32()
            for _ in 0..<count {
                _ = try bytes()
                _ = try bytes()
            }
        }
        return attributes
    }
}
