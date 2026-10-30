import Foundation

/// A fixed, native implementation of the supplied LF source dialect. Imported
/// JavaScript is never evaluated; requests are limited to these LOFTER endpoints.
struct NativeLofterAdapter {
    let source: BookSourceDefinition
    var transport: (@Sendable (String) async throws -> Data)? = nil
    static func accepts(_ source: BookSourceDefinition) -> Bool {
        URL(string: source.bookSourceUrl)?.host?.lowercased() == "api.lofter.com"
            && source.searchUrl?.contains("LF.search") == true
    }
    static let loginURL = URL(string: "https://www.lofter.com/login")!
    static let allowedPaths = Set(["newsearch/post.json", "newsearch/blog.json", "newsearch/collection.json",
        "newsearch/grain.json", "oldapi/post/detail.api", "v1.1/postCollection.api", "v2.0/blogHomePage.api",
        "api-grain/grain/getDetail.json"])

    static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
            + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
    static func address(_ path: String, fields: [String: String], post: Bool = true) -> String {
        let base = "https://api.lofter.com/" + path
        if !post { return base + "?" + form(fields) }
        let options: [String: String] = ["method": "POST", "body": form(fields)]
        let data = try! JSONSerialization.data(withJSONObject: options, options: .sortedKeys)
        return base + "?product=lofter-android-8.3.20," + String(decoding: data, as: UTF8.self)
    }
    static func collection(blog: String, id: String, offset: Int) -> String {
        address("v1.1/postCollection.api", fields: ["method": "getCollectionDetail", "targetblogid": blog,
            "blogid": blog, "collectionid": id, "offset": String(offset), "limit": "200", "order": "1"])
    }
    static func post(blog: String, id: String) -> String {
        address("oldapi/post/detail.api", fields: ["blogdomain": "_blogid_" + blog + ".lofter.com", "postid": id,
            "needgetpoststat": "1", "supportposttypes": "1,2,3,4,5,6", "requestType": "0"])
    }
    static func searchAddress(_ keyword: String, page: Int) -> String {
        var key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var type = "post"
        if key.hasPrefix("#") { type = "collection"; key.removeFirst() }
        else if key.hasPrefix("@") { type = "blog"; key.removeFirst() }
        else if key.hasPrefix("%") { type = "grain"; key.removeFirst() }
        let limit = type == "blog" || type == "grain" ? 10 : 20
        return address("newsearch/" + type + ".json", fields: ["key": key, "limit": String(limit),
            "offset": String(max(0, page - 1) * limit), "sortType": "0", "version": "1"], post: false)
    }
    func request(_ address: String, fresh: Bool = false, attempt: Int = 0) async throws -> [String: Any] {
        let parts = address.components(separatedBy: ",{")
        guard let url = URL(string: parts[0]), url.scheme == "https", url.host == "api.lofter.com",
              Self.allowedPaths.contains(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw SourceEngineError.invalidURL("LOFTER 请求地址不受支持")
        }
        var options: [String: String] = [:]
        if parts.count > 1 {
            options = try JSONDecoder().decode([String: String].self, from: Data(("{" + parts.dropFirst().joined(separator: ",{")).utf8))
        }
        let data: Data
        if let transport { data = try await transport(address) }
        else {
            let client = SourceHTTPClient.shared
            let headers = await client.lofterHeaders()
            data = try await client.fetch(url, source: source, method: options["method"] ?? "GET",
                body: options["body"].map { Data($0.utf8) }, headers: headers, cacheSeconds: fresh ? 0 : 30).data
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceEngineError.invalidResponse }
        let meta = root["meta"] as? [String: Any] ?? [:]
        if let status = Int(Self.string(meta["status"])), status != 200 {
            await SourceHTTPClient.shared.discardCachedResponses(for: source.id)
            if [429, 500, 502, 503, 504].contains(status), attempt < 2 {
                try await Task.sleep(for: .seconds(attempt + 1))
                return try await request(address, fresh: true, attempt: attempt + 1)
            }
            if status == 401 || status == 403 { throw SourceEngineError.authenticationRequired("LOFTER 需要登录或没有此内容的访问权限，请登录书源后重试。") }
            throw SourceEngineError.requestFailed("LOFTER：" + Self.string(meta["msg"]))
        }
        if let code = Int(Self.string(root["code"])), code != 0 && code != 200 {
            await SourceHTTPClient.shared.discardCachedResponses(for: source.id)
            throw SourceEngineError.requestFailed("LOFTER：" + Self.string(root["msg"] ?? root["message"]))
        }
        return root
    }
    func search(keyword: String, page: Int) async throws -> [SearchBook] {
        let root = try await request(Self.searchAddress(keyword, page: page))
        return books(root)
    }
    func books(_ root: [String: Any]) -> [SearchBook] {
        let d = root["data"] as? [String: Any] ?? [:], r = root["response"] as? [String: Any] ?? [:]
        var result: [SearchBook] = []
        for (key, type) in [("collections", "collection"), ("posts", "post"), ("blogs", "blog"), ("grainList", "grain"), ("items", "post"), ("list", "post")] {
            for payload in [d, r] { result += Self.rows(payload[key]).compactMap { entry($0, type: type) } }
        }
        for (key, type) in [("collection", "collection"), ("insertion", "post")] {
            if let value = d[key] as? [String: Any], let book = entry(value, type: type) { result.append(book) }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }
    func entry(_ x: [String: Any], type: String) -> SearchBook? {
        let data = x["postData"] as? [String: Any] ?? [:]
        let p = x["post"] as? [String: Any] ?? x["postView"] as? [String: Any] ?? data["postView"] as? [String: Any] ?? data["post"] as? [String: Any] ?? x
        let b = p["blogInfo"] as? [String: Any] ?? x["blogInfo"] as? [String: Any] ?? data["blogInfo"] as? [String: Any] ?? [:]
        let bid = Self.string(p["blogId"] ?? b["blogId"] ?? x["blogId"])
        let id = Self.string(p["id"] ?? p["postId"] ?? x["id"])
        var name = Self.string(p["title"] ?? p["noticeLinkTitle"])
        var link = Self.post(blog: bid, id: id)
        if type == "collection" { name = Self.string(p["name"]); link = Self.collection(blog: bid, id: id, offset: 0) }
        if type == "blog" { name = Self.string(p["blogNickName"] ?? p["blogName"]); link = Self.address("v2.0/blogHomePage.api", fields: ["targetblogid": bid, "method": "getBlogInfoDetail", "returnData": "1", "checkpwd": "1"]) }
        if type == "grain" { name = Self.string(p["name"]); link = Self.address("api-grain/grain/getDetail.json", fields: ["grainId": id, "grainUserId": Self.string(p["userId"]), "offset": "0"], post: false) }
        if name.isEmpty { name = String(ReadableContentFormatter.plainText(from: Self.string(p["digest"] ?? p["caption"] ?? p["content"])).prefix(50)) }
        guard !name.isEmpty, !bid.isEmpty || type == "grain", !id.isEmpty || type == "blog" else { return nil }
        let image = p["firstImage"] as? [String: Any] ?? [:]
        let urls = p["firstImageUrl"] as? [String] ?? []
        return SearchBook(sourceID: source.id, sourceName: source.bookSourceName, name: ReadableContentFormatter.plainText(from: name),
            author: Self.string(b["blogNickName"] ?? p["blogNickName"] ?? p["blogName"]),
            intro: ReadableContentFormatter.plainText(from: Self.string(p["description"] ?? p["selfIntro"] ?? p["digest"] ?? p["caption"])),
            kind: type == "collection" ? "合集" : type == "blog" ? "作者作品" : "LOFTER",
            lastChapter: "", updateTime: "", bookURL: link,
            coverURL: Self.string(p["coverUrl"] ?? urls.first ?? image["orign"] ?? image["raw"] ?? p["bigAvaImg"] ?? b["bigAvaImg"]), tocURL: "")
    }
    func details(_ book: SearchBook) async throws -> SearchBook {
        let root = try await request(book.bookURL)
        let r = root["response"] as? [String: Any] ?? root["data"] as? [String: Any] ?? [:]
        var result = book
        if let c = r["collection"] as? [String: Any] {
            result.name = Self.string(c["name"]).nilIfBlank ?? book.name
            result.tocURL = Self.collection(blog: Self.string(c["blogId"]), id: Self.string(c["id"]), offset: 0)
        } else if book.bookURL.contains("getBlogInfoDetail"), let b = r["blogInfo"] as? [String: Any] {
            result.tocURL = Self.address("v2.0/blogHomePage.api", fields: ["targetblogid": Self.string(b["blogId"]), "method": "getPostLists", "offset": "0", "limit": "50", "returnData": "1", "checkpwd": "1"])
        }
        return result
    }
    func chapters(_ book: SearchBook) async throws -> [BookChapter] {
        var address = book.tocURL.nilIfBlank ?? book.bookURL
        var result: [BookChapter] = [], seen = Set<String>(), pages = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard pages.insert(address).inserted else { throw SourceEngineError.requestFailed("LOFTER 目录分页未前进，请刷新目录。") }
            let root = try await request(address)
            let r = root["response"] as? [String: Any] ?? root["data"] as? [String: Any] ?? [:]
            let rows = Self.rows(r["posts"]) + Self.rows(r["items"]) + Self.rows(r["list"])
            var added = 0
            for row in rows {
                if let value = entry(row, type: "post"), seen.insert(value.bookURL).inserted {
                    result.append(BookChapter(title: value.name, url: value.bookURL, index: result.count)); added += 1
                }
            }
            if rows.isEmpty { break } // A collection count can include deleted/private posts.
            guard added > 0 else { throw SourceEngineError.requestFailed("LOFTER 返回了重复目录，已停止以避免遗漏章节。") }
            let fields = Self.fields(in: address)
            let current = Int(fields["offset"] ?? "0") ?? 0
            let total = (r["collection"] as? [String: Any])?["postCount"] as? Int
            if let total, current + rows.count >= total { return result }
            let reported = r["offset"] as? Int
            let limit = Int(fields["limit"] ?? "50") ?? 50
            let next = reported.flatMap { $0 > current ? $0 : nil } ?? (current + rows.count)
            if total == nil, (reported == -1 || (reported == nil && rows.count < limit)) { return result }
            if address.contains("postCollection"), let c = r["collection"] as? [String: Any] {
                address = Self.collection(blog: Self.string(c["blogId"]), id: Self.string(c["id"]), offset: next)
            } else if address.contains("getPostLists") || address.contains("api-grain") {
                address = address.replacingOccurrences(of: "offset=" + String(current), with: "offset=" + String(next))
            } else { return result }
        }
        guard !result.isEmpty else { throw SourceEngineError.emptyChapterList }
        if pages.count == 100 { throw SourceEngineError.tocPaginationLimit(100) }
        return result
    }
    func content(_ chapter: BookChapter) async throws -> String {
        try await document(chapter).text
    }
    func document(_ chapter: BookChapter) async throws -> SourceChapterDocument {
        let root = try await request(chapter.url, fresh: true)
        return try Self.document(from: root)
    }
    static func document(from root: [String: Any]) throws -> SourceChapterDocument {
        let r = root["response"] as? [String: Any] ?? root["data"] as? [String: Any] ?? [:]
        guard let wrapper = Self.rows(r["posts"]).first else {
            throw SourceEngineError.authenticationRequired("LOFTER 没有返回正文，请登录书源并确认有权阅读该文章。")
        }
        let nested = wrapper["postData"] as? [String: Any] ?? wrapper
        let p = nested["post"] as? [String: Any] ?? nested["postView"] as? [String: Any] ?? nested
        let long = p["longInfo"] as? [String: Any] ?? [:]
        var html = Self.string(p["content"]).nilIfBlank ?? Self.string(long["content"]).nilIfBlank ?? Self.string(p["caption"])
        let photos = p["photoPostView"] as? [String: Any] ?? [:]
        let links = p["photoLinks"] as? [Any]
        html += Self.images(links?.isEmpty == false ? links : photos["photoLinks"])
        for value in Self.rows(p["returnContent"]) {
            html += "\n" + Self.string(value["content"]) + Self.images(value["images"])
        }
        let text = ReadableTextNormalizer.normalize(ReadableContentFormatter.plainText(from: html))
        if let message = SourceEngine.authenticationMessage(in: text) { throw SourceEngineError.authenticationRequired(message) }
        return try SourceChapterDocument.sanitized(html, baseURL: URL(string: "https://www.lofter.com/")!)
    }
    static func images(_ value: Any?) -> String {
        let values = value as? [Any] ?? []
        return values.compactMap { item -> String? in
            let row = item as? [String: Any] ?? [:]
            let raw = (item as? String) ?? Self.string(row["orign"] ?? row["origin"] ?? row["raw"] ?? row["url"] ?? row["path"])
            guard let url = URL(string: raw, relativeTo: URL(string: "https://www.lofter.com/"))?.absoluteURL,
                  !raw.isEmpty, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            return "<p style=\"text-indent:0;text-align:center\"><img src=\"\(BookEPUBExporter.xml(url.absoluteString))\" alt=\"插图\" /></p>"
        }.joined()
    }
    static func fields(in address: String) -> [String: String] {
        let parts = address.components(separatedBy: ",{")
        var body = ""
        if parts.count > 1, let o = try? JSONDecoder().decode([String: String].self, from: Data(("{" + parts[1]).utf8)) { body = o["body"] ?? "" }
        let query = URLComponents(string: parts[0])?.percentEncodedQuery ?? ""
        return (query + "&" + body).split(separator: "&").reduce(into: [:]) { result, pair in
            let values = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if values.count == 2 { result[String(values[0])] = String(values[1]).removingPercentEncoding ?? String(values[1]) }
        }
    }
    static func string(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value)
    }
    static func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
}
