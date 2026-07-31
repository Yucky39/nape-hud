import Foundation

/// 設定ファイルへの書き戻し。
///
/// config.json には "//..." というキーで大量の説明コメントが書かれている。
/// Codable や JSONSerialization で読み書きすると、そのコメントやキーの並び順が
/// 失われて読めない設定ファイルになってしまう。
/// そこで **該当箇所の文字列だけを外科的に置換する**。
/// 対象が見つからなければ何も書かず `.targetNotFound` を返す
/// （壊すより手で貼ってもらう方がまし、という判断）。
enum ConfigWriter {

    enum Result {
        /// 書き込み成功。バックアップの場所を返す
        case written(backup: URL)
        /// 置換対象が見つからなかった（ファイルは変更していない）
        case targetNotFound
    }

    /// `rules[].angle` の `map` を差し替える。
    static func updateAngleMap(_ mapJSON: String, in url: URL) throws -> Result {
        var text = try String(contentsOf: url, encoding: .utf8)

        guard let angle = objectRange(after: "\"angle\"", in: text) else {
            return .targetNotFound
        }

        if let map = objectRange(after: "\"map\"", in: text, searchRange: angle) {
            // 既存の map を置換
            text.replaceSubrange(map, with: mapJSON)
        } else if let insertAt = insertionPoint(inObject: angle, of: text) {
            // map が無いので追記する
            text.insert(contentsOf: ",\n        \"map\": \(mapJSON)", at: insertAt)
        } else {
            return .targetNotFound
        }
        return try commit(text, to: url)
    }

    /// `["hud", "seconds"]` のような経路に値を書き込む（複数まとめて）。
    /// 値は JSON リテラルの文字列で渡す（`"2.2"` `"true"` `"\"topRight\""` など）。
    ///
    /// 経路の各段はオブジェクトである前提。無いキーは末尾に追記する。
    static func setValues(_ updates: [(path: [String], json: String)], in url: URL) throws -> Result {
        var text = try String(contentsOf: url, encoding: .utf8)
        var wrote = 0

        for update in updates {
            guard !update.path.isEmpty else { continue }
            // 親オブジェクトまで降りる
            var scope: Range<String.Index>? = nil     // nil = ファイル全体
            var ok = true
            for key in update.path.dropLast() {
                guard let r = objectRange(after: "\"\(key)\"", in: text, searchRange: scope) else {
                    ok = false; break
                }
                scope = r
            }
            guard ok else { continue }

            let leaf = update.path[update.path.count - 1]
            if let r = valueRange(after: "\"\(leaf)\"", in: text, searchRange: scope) {
                text.replaceSubrange(r, with: update.json)
                wrote += 1
            } else if let parent = scope, let at = insertionPoint(inObject: parent, of: text) {
                text.insert(contentsOf: ",\n    \"\(leaf)\": \(update.json)", at: at)
                wrote += 1
            }
        }

        guard wrote > 0 else { return .targetNotFound }
        return try commit(text, to: url)
    }

    /// 書き込み前に JSON として妥当か検算する。壊れた設定を書いて起動不能にしないため。
    private static func commit(_ text: String, to url: URL) throws -> Result {
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw Err("書き換え結果が JSON として壊れていたため、保存を中止しました。")
        }
        let backup = try makeBackup(of: url)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .written(backup: backup)
    }

    // MARK: - JSON の構造を壊さずに範囲を探す

    /// `key` の直後にある `{ ... }` の範囲（波括弧を含む）を返す。
    /// 文字列リテラル内の波括弧は無視する。
    private static func objectRange(after key: String, in text: String,
                                    searchRange: Range<String.Index>? = nil) -> Range<String.Index>? {
        let scope = searchRange ?? text.startIndex..<text.endIndex
        guard let keyRange = text.range(of: key, range: scope) else { return nil }

        // key の後ろの `:` と空白を飛ばして `{` を探す
        var i = keyRange.upperBound
        var sawColon = false
        while i < scope.upperBound {
            let ch = text[i]
            if ch == ":" { sawColon = true }
            else if ch == "{" { break }
            else if !ch.isWhitespace { return nil }   // 想定外の並び
            i = text.index(after: i)
        }
        guard sawColon, i < scope.upperBound, text[i] == "{" else { return nil }

        guard let end = matchBrace(from: i, in: text, limit: scope.upperBound) else { return nil }
        return i..<text.index(after: end)
    }

    /// `key` の直後にある値（スカラー / 文字列 / 配列 / オブジェクト）の範囲を返す。
    private static func valueRange(after key: String, in text: String,
                                   searchRange: Range<String.Index>? = nil) -> Range<String.Index>? {
        let scope = searchRange ?? text.startIndex..<text.endIndex
        guard let keyRange = text.range(of: key, range: scope) else { return nil }

        // `:` と空白を飛ばして値の先頭へ
        var i = keyRange.upperBound
        var sawColon = false
        while i < scope.upperBound {
            let ch = text[i]
            if ch == ":" { sawColon = true; i = text.index(after: i); continue }
            if ch.isWhitespace { i = text.index(after: i); continue }
            break
        }
        guard sawColon, i < scope.upperBound else { return nil }

        switch text[i] {
        case "{":
            guard let end = matchBrace(from: i, in: text, limit: scope.upperBound, open: "{", close: "}")
            else { return nil }
            return i..<text.index(after: end)
        case "[":
            guard let end = matchBrace(from: i, in: text, limit: scope.upperBound, open: "[", close: "]")
            else { return nil }
            return i..<text.index(after: end)
        case "\"":
            var j = text.index(after: i)
            var escaped = false
            while j < scope.upperBound {
                let c = text[j]
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { return i..<text.index(after: j) }
                j = text.index(after: j)
            }
            return nil
        default:
            // 数値 / true / false / null
            var j = i
            while j < scope.upperBound, !",}]\n".contains(text[j]) { j = text.index(after: j) }
            // 末尾の空白を含めない
            var end = j
            while end > i, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            return i..<end
        }
    }

    /// `open` の位置にある `{` に対応する `}` の位置を返す。
    private static func matchBrace(from open: String.Index, in text: String,
                                   limit: String.Index,
                                   open openCh: Character = "{",
                                   close closeCh: Character = "}") -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < limit {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == openCh {
                depth += 1
            } else if ch == closeCh {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// オブジェクトの閉じ括弧の直前（末尾要素の後ろ）を返す。追記用。
    private static func insertionPoint(inObject range: Range<String.Index>,
                                       of text: String) -> String.Index? {
        // range は `{` から `}` の次まで。閉じ括弧は range の 1 つ前
        var i = text.index(before: range.upperBound)   // `}`
        guard text[i] == "}" else { return nil }
        // 直前の非空白位置まで戻る
        while i > range.lowerBound {
            let prev = text.index(before: i)
            if !text[prev].isWhitespace { return i == range.lowerBound ? nil : text.index(after: prev) }
            i = prev
        }
        return nil
    }

    // MARK: -

    private static func makeBackup(of url: URL) throws -> URL {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = stamp.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let backup = url.deletingPathExtension()
            .appendingPathExtension("\(name).bak.json")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }
}
