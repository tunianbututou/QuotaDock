import Foundation

public enum WireValue: Codable, Equatable, Sendable {
    case record([String: WireValue])
    case list([WireValue])
    case text(String)
    case decimal(Double)
    case flag(Bool)
    case nothing

    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()

        if box.decodeNil() {
            self = .nothing
            return
        }

        // 依次试解各类型。布尔先于数字：JSON 的 true/false 在部分解码器里也能读成 1/0，
        // 反过来则不会；字典与数组放最后，避免标量被容器类型吞掉。
        if let flag = Self.probe(Bool.self, in: box) {
            self = .flag(flag)
        } else if let amount = Self.probe(Double.self, in: box) {
            self = .decimal(amount)
        } else if let text = Self.probe(String.self, in: box) {
            self = .text(text)
        } else if let pairs = Self.probe([String: WireValue].self, in: box) {
            self = .record(pairs)
        } else if let items = Self.probe([WireValue].self, in: box) {
            self = .list(items)
        } else {
            throw DecodingError.dataCorruptedError(
                in: box,
                debugDescription: "JSON 值类型不受支持"
            )
        }
    }

    private static func probe<T: Decodable>(
        _ type: T.Type,
        in box: SingleValueDecodingContainer
    ) -> T? {
        try? box.decode(type)
    }

    public func encode(to encoder: Encoder) throws {
        var sink = encoder.singleValueContainer()

        switch self {
        case let .record(pairs): try sink.encode(pairs)
        case let .list(items): try sink.encode(items)
        case let .text(text): try sink.encode(text)
        case let .decimal(amount): try sink.encode(amount)
        case let .flag(flag): try sink.encode(flag)
        case .nothing: try sink.encodeNil()
        }
    }
}

public extension WireValue {
    /// 载荷提不出来就是 nil —— 调用方用 `if let` / `??` 处理即可，不必猜类型
    var asRecord: [String: WireValue]? {
        if case let .record(pairs) = self { return pairs }
        return nil
    }

    var asList: [WireValue]? {
        if case let .list(items) = self { return items }
        return nil
    }

    var asText: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var asDecimal: Double? {
        if case let .decimal(value) = self { return value }
        return nil
    }

    /// 协议里的 id 是整数，但 JSON 只有一种数字类型
    var asInteger: Int? {
        asDecimal.map(Int.init)
    }

    var asTruthy: Bool? {
        if case let .flag(value) = self { return value }
        return nil
    }

    subscript(key: String) -> WireValue? {
        asRecord?[key]
    }
}
