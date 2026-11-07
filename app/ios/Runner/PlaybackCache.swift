import Foundation
import Network
import JavaScriptCore
import CryptoKit

/// An on-device HLS gateway. Actual media downloads use a system background
/// URLSession, so pausing WebKit does not cancel the next playback window.
@objc final class PlaybackCache: NSObject, URLSessionDownloadDelegate {
    @objc static let shared = PlaybackCache()
    @objc static let identifier = "app.bahaplus.mobile.hls-cache"
    private let queue = DispatchQueue(label: "app.bahaplus.mobile.hls-cache")
    private let delegateQueue = OperationQueue()
    private let root: URL
    private let sessionID = PlaybackCache.identifier
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var token = ""
    private var document = ""
    private var videoID = ""
    private var position: Double = 0
    private var resources: [String: Resource] = [:]
    private var playlists: [String: [[String: Any]]] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var failed = Set<String>()
    private var excludedPrefetch = Set<String>()
    private var waiters: [String: [(NWConnection, String?, Bool)]] = [:]
    private var backgroundCompletion: (() -> Void)?
    private var reconnecting = false
    private var connections = Set<ObjectIdentifier>()
    private let maximumBytes: Int64 = 96 * 1024 * 1024
    private let maximumResourceBytes: Int64 = 24 * 1024 * 1024
    private struct Resource {
        let url: URL
        let kind: String
        let role: String
    }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionID)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    private lazy var manifests: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private override init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackCache", isDirectory: true)
        super.init()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        restore()
        for item in (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if UUID(uuidString: item.lastPathComponent) != nil && item.lastPathComponent != token {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    /// No URLs, cookies, or media bytes leave the device. Call only after the
    /// origin/episode-bound official bridge has declared the content phase.
    @objc func prepare(_ arguments: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            guard let source = arguments["source"] as? String, let url = self.allowed(source),
                  url.pathExtension.lowercased() == "m3u8",
                  let ticket = arguments["document"] as? String,
                  ticket.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil,
                  let video = arguments["videoId"] as? String,
                  video.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            if self.document != ticket {
                self.reset()
                self.token = UUID().uuidString
                self.document = ticket
                self.videoID = video
            }
            self.resources[source] = Resource(url: url, kind: "playlist", role: "video")
            self.persist()
            self.startListener { ready in
                let result: [String: Any]? = ready ? ["base": self.baseURL, "url": self.localURL(url)] : nil
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    @objc func update(_ arguments: [String: Any]) {
        queue.async {
            guard arguments["document"] as? String == self.document,
                  let time = arguments["position"] as? Double, time.isFinite, time >= 0 else { return }
            self.position = time
            self.prefetch()
        }
    }

    @objc func stop(_ ticket: String) {
        queue.async {
            guard ticket == self.document else { return }
            self.reset()
        }
    }

    @objc func reconnect(_ completion: @escaping () -> Void) {
        queue.async {
            self.backgroundCompletion = completion
            self.reconnecting = true
            self.session.getAllTasks { items in
                self.queue.async {
                    for item in items {
                        guard let task = item as? URLSessionDownloadTask,
                              let description = task.taskDescription,
                              description.hasPrefix(self.token + "\n") else { item.cancel(); continue }
                        let url = String(description.dropFirst(self.token.count + 1))
                        guard self.resources[url] != nil else { item.cancel(); continue }
                        self.tasks[url] = task
                    }
                    self.reconnecting = false
                    self.prefetch()
                }
            }
        }
    }

    private var baseURL: String { "http://localhost:\(port)/\(token)/" }
    private func localURL(_ url: URL) -> String {
        let ext = url.pathExtension.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) != nil
            ? url.pathExtension : "bin"
        var value = URLComponents(string: baseURL + "media." + ext)!
        value.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]
        return value.url!.absoluteString
    }
    private func allowed(_ raw: String) -> URL? {
        guard raw.count <= 4096, let url = URL(string: raw), url.scheme == "https",
              url.host == "bahamut.akamaized.net", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    private func file(_ source: String) -> URL {
        let hash = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(token, isDirectory: true).appendingPathComponent(hash)
    }
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("https://ani.gamer.com.tw", forHTTPHeaderField: "Origin")
        request.setValue("https://ani.gamer.com.tw/animeVideo.php?sn=" + videoID, forHTTPHeaderField: "Referer")
        return request
    }
    private func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for waiting in waiters.values {
            for (connection, _, _) in waiting { reply(connection, status: 410) }
        }
        waiters.removeAll()
        listener?.cancel(); listener = nil; port = 0
        resources.removeAll(); playlists.removeAll(); failed.removeAll(); excludedPrefetch.removeAll()
        if !token.isEmpty { try? FileManager.default.removeItem(at: root.appendingPathComponent(token)) }
        token = ""; document = ""; videoID = ""; position = 0
        persist()
    }
    private func startListener(_ completion: @escaping (Bool) -> Void) {
        if port > 0 { completion(true); return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server
            var answered = false
            server.stateUpdateHandler = { state in
                guard self.listener === server else {
                    server.stateUpdateHandler = nil
                    server.newConnectionHandler = nil
                    server.cancel()
                    if !answered { answered = true; completion(false) }
                    return
                }
                if case .ready = state, let port = server.port {
                    self.port = port.rawValue
                    if !answered { answered = true; completion(true) }
                } else if case .failed = state {
                    server.stateUpdateHandler = nil
                    server.newConnectionHandler = nil
                    self.listener = nil; self.port = 0
                    if !answered { answered = true; completion(false) }
                } else if case .cancelled = state {
                    server.stateUpdateHandler = nil
                    server.newConnectionHandler = nil
                    if !answered { answered = true; completion(false) }
                }
            }
            server.newConnectionHandler = { connection in self.accept(connection) }
            server.start(queue: queue)
        } catch { completion(false) }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let identity = ObjectIdentifier(connection)
        connections.insert(identity)
        connection.stateUpdateHandler = { state in
            if case .cancelled = state {
                connection.stateUpdateHandler = nil
                self.connections.remove(identity)
            }
            if case .failed = state {
                connection.stateUpdateHandler = nil
                self.connections.remove(identity); connection.cancel()
            }
        }
        connection.start(queue: queue)
        receive(connection, bytes: Data())
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
            var buffer = bytes
            if let data = data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                self.handle(connection, header: text)
            } else if done { connection.cancel() }
            else { self.receive(connection, bytes: buffer) }
        }
    }
    private func handle(_ connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3, ["GET", "HEAD", "OPTIONS"].contains(first[0]) else { reply(connection, status: 405); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "localhost:\(port)",
              headers["origin"] == nil || headers["origin"] == "https://ani.gamer.com.tw",
              let components = URLComponents(string: "http://localhost" + first[1]),
              components.path.hasPrefix("/" + token + "/"),
              !token.isEmpty else { reply(connection, status: 403); return }
        if first[0] == "OPTIONS" { reply(connection, status: 204); return }
        guard let source = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let resource = resources[source] else { reply(connection, status: 404); return }
        let head = first[0] == "HEAD"
        if resource.kind == "playlist" {
            let ticket = token
            manifests.dataTask(with: request(resource.url)) { data, response, error in
                guard ticket == self.token else { self.reply(connection, status: 410); return }
                guard error == nil, let response = response as? HTTPURLResponse,
                      response.statusCode == 200, let finalURL = response.url,
                      self.allowed(finalURL.absoluteString) != nil,
                      let data = data, data.count <= 500000,
                      let text = String(data: data, encoding: .utf8),
                      let parsed = self.parse(text, base: finalURL, role: resource.role),
                      let output = parsed["text"] as? String else {
                    self.reply(connection, status: 502); return
                }
                if resource.role != "iframes", parsed["endList"] as? Bool == true,
                   let segments = parsed["segments"] as? [[String: Any]] {
                    self.playlists[resource.role] = segments
                    self.persist()
                    self.prefetch()
                }
                self.reply(connection, status: 200, data: Data(output.utf8),
                    type: "application/vnd.apple.mpegurl", head: head)
            }.resume()
            return
        }
        if FileManager.default.fileExists(atPath: file(source).path) {
            serve(connection, source: source, range: headers["range"], head: head)
        } else {
            waiters[source, default: []].append((connection, headers["range"], head))
            tasks[source]?.priority = URLSessionTask.highPriority
            download(source)
        }
    }
    private func parse(_ text: String, base: URL, role: String) -> [String: Any]? {
        guard let scriptURL = Bundle.main.url(forResource: "hls-cache-playlist", withExtension: "js"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let context = JSContext() else { return nil }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript(script)
        let resolve: @convention(block) (String) -> String? = { raw in
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  self.allowed(url.absoluteString) != nil else { return nil }
            return url.absoluteString
        }
        let rewrite: @convention(block) (String, String, String) -> String? = { raw, kind, track in
            guard let url = self.allowed(raw), self.resources.count < 30000 else { return nil }
            self.resources[raw] = Resource(url: url, kind: kind, role: track)
            return self.localURL(url)
        }
        let result = context.objectForKeyedSubscript("parseHlsCachePlaylist")?.call(
            withArguments: [text, resolve as AnyObject, rewrite as AnyObject, role])?.toDictionary() as? [String: Any]
        return failed ? nil : result
    }
    private func prefetch() {
        var wanted = Set<String>()
        var ordered: [String] = []
        for segments in playlists.values {
            for segment in segments {
                guard let start = segment["start"] as? Double, let duration = segment["duration"] as? Double,
                      start + duration >= position, start <= position + 120,
                      let url = segment["url"] as? String else { continue }
                for dependency in segment["dependencies"] as? [String] ?? [] {
                    if wanted.insert(dependency).inserted { ordered.append(dependency) }
                }
                if wanted.insert(url).inserted { ordered.append(url) }
            }
        }
        excludedPrefetch.formIntersection(wanted)
        // Keep foreground requests and cancel speculative work outside the new
        // seek/quality window. The system limits concurrent network transfers.
        for (source, task) in tasks where !wanted.contains(source) && waiters[source] == nil {
            task.cancel()
        }
        let directory = root.appendingPathComponent(token)
        for source in resources.keys where !wanted.contains(source) && waiters[source] == nil {
            // Media outside the current read-ahead window is no longer needed.
            if resources[source]?.kind != "playlist" { try? FileManager.default.removeItem(at: file(source)) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var used: Int64 = 0
        for url in files {
            used += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if used >= maximumBytes { return }
        for source in ordered where !failed.contains(source) && !excludedPrefetch.contains(source) {
            if tasks.count >= 8 { break }
            if !FileManager.default.fileExists(atPath: file(source).path) { download(source) }
        }
    }
    private func download(_ source: String) {
        guard tasks[source] == nil, let resource = resources[source], resource.kind != "playlist",
              !token.isEmpty else { return }
        let task = session.downloadTask(with: request(resource.url))
        task.taskDescription = token + "\n" + source
        task.priority = waiters[source] == nil ? URLSessionTask.lowPriority : URLSessionTask.highPriority
        tasks[source] = task
        task.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allowed(url.absoluteString) != nil else { completionHandler(nil); return }
        completionHandler(self.request(url))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumResourceBytes || totalBytesExpectedToWrite > maximumResourceBytes {
            downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription, description.hasPrefix(token + "\n"),
              let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, allowed(finalURL.absoluteString) != nil else { return }
        let source = String(description.dropFirst(token.count + 1))
        guard resources[source] != nil else { return }
        do {
            let destination = file(source)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            let size = (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let files = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            var used = files.reduce(Int64(0)) {
                $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            for old in files.sorted(by: {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }) where used + Int64(size) > maximumBytes {
                let oldSize = (try? old.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try FileManager.default.removeItem(at: old)
                for source in resources.keys where file(source) == old {
                    excludedPrefetch.insert(source)
                }
                used -= Int64(oldSize)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        } catch { /* The normal stream can fall back to the official source. */ }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription, description.hasPrefix(token + "\n") else { return }
        let source = String(description.dropFirst(token.count + 1))
        guard tasks[source] == nil || tasks[source]?.taskIdentifier == task.taskIdentifier else { return }
        tasks.removeValue(forKey: source)
        if error != nil || !FileManager.default.fileExists(atPath: file(source).path) { failed.insert(source) }
        let pending = waiters.removeValue(forKey: source) ?? []
        for (connection, range, head) in pending {
            if error == nil, FileManager.default.fileExists(atPath: file(source).path) {
                serve(connection, source: source, range: range, head: head)
            } else { reply(connection, status: 502) }
        }
        if !reconnecting { prefetch() }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { completion?() }
    }
    private func serve(_ connection: NWConnection, source: String, range: String?, head: Bool) {
        guard let data = try? Data(contentsOf: file(source)), data.count <= maximumResourceBytes else {
            reply(connection, status: 502); return
        }
        var lower = 0, upper = data.count - 1, status = 200
        var extra = ""
        if let range = range {
            let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-", omittingEmptySubsequences: false)
            guard range.hasPrefix("bytes="), parts.count == 2, !range.contains(","), data.count > 0 else {
                reply(connection, status: 416, extra: "Content-Range: bytes */\(data.count)\r\n"); return
            }
            if parts[0].isEmpty {
                guard let suffix = Int(parts[1]), suffix > 0 else { reply(connection, status: 416); return }
                lower = max(0, data.count - suffix)
            } else {
                guard let start = Int(parts[0]), start >= 0, start < data.count else {
                    reply(connection, status: 416, extra: "Content-Range: bytes */\(data.count)\r\n"); return
                }
                lower = start
                if !parts[1].isEmpty {
                    guard let end = Int(parts[1]), end >= start else { reply(connection, status: 416); return }
                    upper = min(end, upper)
                }
            }
            status = 206
            extra = "Content-Range: bytes \(lower)-\(upper)/\(data.count)\r\n"
        }
        let kind = resources[source]?.kind
        let ext = resources[source]?.url.pathExtension.lowercased()
        let type = kind == "key" ? "application/octet-stream" :
            ext == "ts" ? "video/mp2t" : ext == "vtt" ? "text/vtt" :
            ext == "aac" ? "audio/aac" : ext == "m4a" ? "audio/mp4" : "video/mp4"
        let output = data.isEmpty ? Data() : data.subdata(in: lower..<(upper + 1))
        reply(connection, status: status, data: output, type: type, head: head, extra: extra)
    }
    private func reply(_ connection: NWConnection, status: Int, data: Data = Data(),
                       type: String = "text/plain", head: Bool = false, extra: String = "") {
        let reason = [200: "OK", 204: "No Content", 206: "Partial Content", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 410: "Gone",
            416: "Range Not Satisfiable", 502: "Bad Gateway"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Type: \(type)\r\n" +
            "Content-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n" +
            "Access-Control-Allow-Origin: https://ani.gamer.com.tw\r\n" +
            "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: Range\r\n" +
            "Access-Control-Allow-Private-Network: true\r\n" +
            "Access-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges\r\n" + extra + "\r\n"
        var body = Data(headers.utf8)
        if !head { body.append(data) }
        connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func persist() {
        var entries: [String: Any] = [:]
        for (source, resource) in resources {
            entries[source] = ["kind": resource.kind, "role": resource.role]
        }
        let state: [String: Any] = ["token": token, "document": document,
            "videoId": videoID, "resources": entries, "playlists": playlists, "position": position]
        guard let bytes = try? JSONSerialization.data(withJSONObject: state) else { return }
        try? bytes.write(to: root.appendingPathComponent("state.json"), options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: root.appendingPathComponent("state.json").path)
    }
    private func restore() {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let savedToken = state["token"] as? String, UUID(uuidString: savedToken) != nil,
              let savedDocument = state["document"] as? String, savedDocument.count == 48,
              let savedVideo = state["videoId"] as? String else { return }
        token = savedToken; document = savedDocument; videoID = savedVideo
        position = state["position"] as? Double ?? 0
        for (source, item) in state["resources"] as? [String: [String: String]] ?? [:] {
            guard let url = allowed(source), let kind = item["kind"], let role = item["role"] else { continue }
            resources[source] = Resource(url: url, kind: kind, role: role)
        }
        playlists = state["playlists"] as? [String: [[String: Any]]] ?? [:]
    }
}
