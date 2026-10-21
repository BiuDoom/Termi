import Foundation

/// Identity of a file by the exact bytes of its path. Swift compares strings by canonical
/// equivalence — "é" precomposed equals "e" + U+0301 — but to a server those are two files, so
/// selections, the list of files being edited and every "is this the same path" question use
/// this key instead of `String ==`.
struct SFTPPathKey: Hashable, Sendable {
    private let path: String
    /// Set for a listed name that is not valid UTF-8 (see `SFTPItem.rawName`): two such names
    /// can share one display text, and neither is the file whose name really is that text.
    private let rawName: Data?

    init(_ path: String, rawName: Data? = nil) {
        self.path = path
        self.rawName = rawName
    }

    static func == (a: SFTPPathKey, b: SFTPPathKey) -> Bool {
        a.path.utf8.elementsEqual(b.path.utf8) && a.rawName == b.rawName
    }

    func hash(into hasher: inout Hasher) {
        let hashed: Void? = path.utf8.withContiguousStorageIfAvailable {
            hasher.combine(bytes: UnsafeRawBufferPointer($0))
        }
        if hashed == nil {
            for byte in path.utf8 { hasher.combine(byte) }
        }
    }

    /// Whether this path is `ancestor` itself or lies below it, component-wise and bytewise
    /// ("/a/xy" is not below "/a/x"). Returns the bytes after `ancestor` ("" or "/…").
    static func remainder(of path: String, below ancestor: String) -> String? {
        let bytes = path.utf8
        let prefix = ancestor.utf8
        guard bytes.starts(with: prefix) else { return nil }
        let rest = bytes.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first == 0x2F || prefix.last == 0x2F else { return nil }
        return String(Substring(rest))
    }
}

/// A file or directory in an SFTP (remote) or local file listing.
struct SFTPItem: Identifiable, Hashable, Sendable {
    var id: SFTPPathKey { SFTPPathKey(path, rawName: rawName) }
    var name: String
    var path: String
    var isDirectory: Bool
    var isSymlink: Bool = false
    var size: Int64
    /// "drwxr-xr-x" style permission string (empty when unknown).
    var permissions: String
    /// Numeric permission bits (including the file type bits) when known.
    var mode: UInt32? = nil
    var owner: String
    var group: String
    var modified: Date?
    /// The name as the server sent it, when those bytes are not valid UTF-8. `name` and `path`
    /// then only hold a text for display: sent back, they would be other bytes — another file
    /// or none. Such an item is listed but nothing can be done with it.
    var rawName: Data? = nil
    /// A link that leads to a pipe, a device or a socket. `mode` is the link's own and does
    /// not say so; the listing asks the server what is behind each link.
    var linksToSpecialFile = false

    var isNameRepresentable: Bool { rawName == nil }

    /// A pipe, a device or a socket, going by the type bits of `mode`, or a link to one.
    /// Opening one to read it can block the server's whole session (a pipe nobody writes to)
    /// or never end (a device).
    var isSpecialFile: Bool {
        linksToSpecialFile || Self.isSpecialFileMode(mode)
    }

    /// A server that sent no permissions said nothing about the type: that is not "special",
    /// or every file of such a server would be.
    static func isSpecialFileMode(_ mode: UInt32?) -> Bool {
        guard let mode else { return false }
        switch mode & 0o170000 {
        case 0o010000, 0o020000, 0o060000, 0o140000: return true
        default: return false
        }
    }

    // Name and path by their bytes, like `id`: two entries that differ only in how an accent
    // is encoded are different files, even when everything else about them is the same.
    static func == (a: SFTPItem, b: SFTPItem) -> Bool {
        a.id == b.id && SFTPPathKey(a.name) == SFTPPathKey(b.name)
            && a.isDirectory == b.isDirectory && a.isSymlink == b.isSymlink && a.size == b.size
            && a.permissions == b.permissions && a.mode == b.mode && a.owner == b.owner
            && a.group == b.group && a.modified == b.modified
            && a.linksToSpecialFile == b.linksToSpecialFile
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var displaySize: String {
        if isDirectory { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    /// Octal permission bits, e.g. "755".
    var octalPermissions: String? {
        mode.map { Self.octalString(ofMode: $0) }
    }

    /// At least three digits ("044", not "44"): the form the permissions field takes back.
    static func octalString(ofMode mode: UInt32) -> String {
        let digits = String(mode & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }

    var icon: String {
        if isDirectory { return isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        if isSymlink { return "link" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log": return "doc.text"
        case "swift", "py", "js", "ts", "rs", "go", "c", "cpp", "h", "java", "rb", "php": return "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "xml", "toml": return "gearshape.2"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "tgz": return "archivebox"
        case "sh", "bash", "zsh": return "terminal"
        case "conf", "cfg", "ini", "env": return "wrench"
        default: return "doc"
        }
    }

    /// Directories first, then case-insensitive by name.
    static func directoriesFirst(_ a: SFTPItem, _ b: SFTPItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

extension SFTPItem {
    /// Build an item from an SFTP directory entry.
    init(entry: SFTPClient.DirectoryEntry, parentPath: String) {
        let attributes = entry.attributes
        self.init(
            name: entry.name,
            path: SFTPClient.join(parentPath, entry.name),
            isDirectory: attributes.fileType == .directory,
            isSymlink: attributes.fileType == .symlink,
            size: Int64(clamping: attributes.size ?? 0),
            permissions: attributes.permissionString,
            mode: attributes.permissions,
            owner: entry.owner ?? attributes.uid.map(String.init) ?? "",
            group: entry.group ?? attributes.gid.map(String.init) ?? "",
            modified: attributes.modificationDate,
            rawName: entry.rawName
        )
    }

    /// Build an item for a local file.
    init?(localURL url: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        // lstat rather than FileManager.attributesOfItem: that one also reads extended attributes,
        // which makes macOS ask for access to Desktop / Documents / Downloads (and blocks the
        // caller until the user answers) merely for listing the folder that contains them.
        var info = stat()
        let hasInfo = lstat(url.path, &info) == 0
        let mode: UInt32? = hasInfo ? UInt32(info.st_mode) & 0o7777 : nil
        let isDirectory = values.isDirectory ?? false
        self.init(
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            isSymlink: values.isSymbolicLink ?? false,
            size: Int64(values.fileSize ?? 0),
            permissions: mode.map {
                SFTPClient.Attributes(permissions: $0 | (isDirectory ? 0o040000 : 0o100000)).permissionString
            } ?? "",
            mode: mode,
            owner: hasInfo ? localUserName(info.st_uid) : "",
            group: hasInfo ? localGroupName(info.st_gid) : "",
            modified: values.contentModificationDate
        )
    }
}

// File scope: inside `SFTPItem`, `group` is the stored property, not the C struct.

private func localUserName(_ uid: uid_t) -> String {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 1024)
    guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, result != nil,
          let name = entry.pw_name else { return String(uid) }
    return String(cString: name)
}

private func localGroupName(_ gid: gid_t) -> String {
    var entry = group()
    var result: UnsafeMutablePointer<group>?
    var buffer = [CChar](repeating: 0, count: 1024)
    guard getgrgid_r(gid, &entry, &buffer, buffer.count, &result) == 0, result != nil,
          let name = entry.gr_name else { return String(gid) }
    return String(cString: name)
}
