/// Renumbers an offer's RTP header extensions to agree with the room's.
///
/// When the room offers first (a caller that subscribes before publishing), the SFU picks the ids.
/// libwebrtc then numbers a newly added section on its own and can put two extensions on one id
/// ("BUNDLE group contains a codec collision for header extension"), which fails the publish.
/// Every extension keeps the room's id where the room has one, and one id across all sections.
enum Extmap {
    static func align(_ local: String, toRemote remote: String?) -> String {
        guard let remote else { return local }
        var idByUri: [String: Int] = [:]
        for line in remote.components(separatedBy: "\r\n") {
            if let (id, uri, _) = parse(line) { idByUri[uri] = id }
        }
        var used = Set(idByUri.values)
        let lines = local.components(separatedBy: "\r\n").compactMap { line -> String? in
            guard let (id, uri, rest) = parse(line) else { return line }
            let chosen: Int
            if let known = idByUri[uri] {
                chosen = known
            } else if !used.contains(id) {
                chosen = id
            } else if let free = (1...14).first(where: { !used.contains($0) }) {
                chosen = free
            } else {
                return nil  // no one-byte id left: drop the extension rather than collide
            }
            idByUri[uri] = chosen
            used.insert(chosen)
            return "a=extmap:\(chosen)\(rest)"
        }
        return lines.joined(separator: "\r\n")
    }

    /// `a=extmap:<id>[/direction] <uri>[ attributes]` → (id, uri, everything after the id).
    private static func parse(_ line: String) -> (Int, String, String)? {
        guard line.hasPrefix("a=extmap:") else { return nil }
        let body = line.dropFirst("a=extmap:".count)
        guard let space = body.firstIndex(of: " ") else { return nil }
        let idPart = body[..<space]
        let idDigits = idPart.prefix { $0.isNumber }
        guard let id = Int(idDigits) else { return nil }
        let rest = String(body[idDigits.endIndex...])
        let uri = body[body.index(after: space)...].split(separator: " ").first.map(String.init) ?? ""
        return (id, uri, rest)
    }
}
