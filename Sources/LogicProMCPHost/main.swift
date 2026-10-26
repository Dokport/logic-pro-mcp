// LogicProMCPHost: the one process that holds Accessibility for Logic Pro MCP.
//
// Why it exists. macOS grants Accessibility to the RESPONSIBLE process of whatever asks. A
// server spawned by a client (Claude Code, a terminal) inherits that client as its responsible
// process, so the client had to hold Accessibility, and with it every program the client runs
// could drive every app on the machine. Started by launchd, this host is responsible for itself,
// and the servers it spawns inherit it. Accessibility is then granted to this host alone, and a
// client reaches Logic only through the server's fixed MCP tools.
//
// What it does, and nothing more:
//   - listens on a Unix socket in the user's Application Support folder, mode 0600, and accepts
//     only peers with the user's own uid;
//   - for each connection, spawns the sibling `LogicProMCP` server with the socket as its stdin
//     and stdout, and waits for it before accepting the next one: two servers driving Logic's UI
//     at once would race each other;
//   - on start, if it is not trusted, asks macOS once to show the Accessibility prompt, which also
//     lists it in System Settings.
//
// The server it runs is always the `LogicProMCP` beside its own executable, inside the same signed
// bundle. There is deliberately no option to name another program: whoever starts the host would
// otherwise get any code they chose run with the host's Accessibility.
//
//   LogicProMCPHost [--socket PATH] [--log PATH] [--check]
import ApplicationServices
import Darwin
import Foundation

struct Options {
    var socketPath: String
    var serverPath: String
    var logPath: String
    var check = false
}

func defaultSupportDirectory() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + "/Library/Application Support/LogicProMCP"
}

func parseOptions() -> Options {
    let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().path
    var options = Options(
        socketPath: defaultSupportDirectory() + "/mcp.sock",
        serverPath: executableDirectory + "/LogicProMCP",
        logPath: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/LogicProMCP/server.log"
    )
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--socket": options.socketPath = arguments.next() ?? options.socketPath
        case "--log": options.logPath = arguments.next() ?? options.logPath
        case "--check": options.check = true
        default:
            fail("unknown argument \(argument)")
        }
    }
    return options
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(stamp)] host: \(message)\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    log(message)
    exit(1)
}

/// Accessibility as macOS answers it for this process. With `prompt`, an untrusted host is listed
/// in System Settings and the user is shown the standard dialog.
func accessibilityTrusted(prompt: Bool) -> Bool {
    // The value of kAXTrustedCheckOptionPrompt, spelled out: Swift 6 refuses the global as unsafe.
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func makeListeningSocket(at path: String) -> Int32 {
    let directory = (path as NSString).deletingLastPathComponent
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        fail("cannot create \(directory): \(error)")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else { fail("socket path is longer than \(maxLength - 1) bytes") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))") }
    let previousMask = umask(0o177)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    umask(previousMask)
    guard bound == 0 else { fail("bind \(path): \(String(cString: strerror(errno)))") }
    chmod(path, 0o600)
    guard listen(fd, 4) == 0 else { fail("listen: \(String(cString: strerror(errno)))") }
    return fd
}

/// The peer must be this user. The socket's mode already says so; this does not rely on it.
func peerIsThisUser(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
}

func serverEnvironment() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var environment = [
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME=\(home)",
        "TMPDIR=\(NSTemporaryDirectory())",
        "LANG=en_US.UTF-8",
    ]
    if let user = ProcessInfo.processInfo.environment["USER"] { environment.append("USER=\(user)") }
    return environment
}

/// Runs one server with the connection as its stdin/stdout and the log as its stderr, to the end.
func serve(connection: Int32, options: Options) {
    let logFD = open(options.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, connection, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, connection, STDOUT_FILENO)
    if logFD >= 0 { posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO) }
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(options.serverPath), nil]
    defer { argv.forEach { free($0) } }
    // A fixed environment, not the host's: nothing the host was started with reaches the server.
    let environment = serverEnvironment().map { strdup($0) } + [nil]
    defer { environment.forEach { free($0) } }
    let status = posix_spawn(&pid, options.serverPath, &actions, nil, argv, environment)
    if logFD >= 0 { close(logFD) }
    guard status == 0 else {
        log("spawn \(options.serverPath) failed: \(String(cString: strerror(status)))")
        return
    }
    log("session started, server pid \(pid)")
    var exitStatus: Int32 = 0
    while waitpid(pid, &exitStatus, 0) < 0 && errno == EINTR {}
    log("session ended, server pid \(pid), wait status \(exitStatus)")
}

let options = parseOptions()
signal(SIGPIPE, SIG_IGN)
try? FileManager.default.createDirectory(
    atPath: (options.logPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
)

if options.check {
    print("accessibility_trusted=\(accessibilityTrusted(prompt: false))")
    print("server=\(options.serverPath) exists=\(FileManager.default.isExecutableFile(atPath: options.serverPath))")
    print("socket=\(options.socketPath)")
    exit(0)
}

guard FileManager.default.isExecutableFile(atPath: options.serverPath) else {
    fail("no executable server at \(options.serverPath)")
}
let trusted = accessibilityTrusted(prompt: true)
log("started pid \(getpid()); accessibility_trusted=\(trusted); socket \(options.socketPath)")

let listener = makeListeningSocket(at: options.socketPath)
while true {
    let connection = accept(listener, nil, nil)
    guard connection >= 0 else {
        if errno == EINTR { continue }
        fail("accept: \(String(cString: strerror(errno)))")
    }
    if peerIsThisUser(connection) {
        serve(connection: connection, options: options)
    } else {
        log("refused a connection from another user")
    }
    close(connection)
}
