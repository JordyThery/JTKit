import Foundation

public nonisolated extension LosslessJSON {
    /// Equality that allows for server canonicalization: object key order is
    /// ignored and numbers compare by value (`1.0` equals `1`). Arrays stay
    /// ordered, strings and booleans compare exactly. Duplicate keys compare by
    /// their first occurrence, as `LosslessJSON.Object` reads them.
    func isSemanticallyEqual(to other: LosslessJSON) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.number(a), .number(b)):
            if a.literal == b.literal { return true }
            guard let left = Decimal(string: a.literal, locale: Locale(identifier: "en_US_POSIX")),
                  let right = Decimal(string: b.literal, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            guard left == right else { return false }
            // Decimal holds 38 significant digits; differing literals longer than
            // that could collide, so they count as unequal rather than equal.
            return Self.significantDigits(a.literal) <= 38 && Self.significantDigits(b.literal) <= 38
        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isSemanticallyEqual(to: $1) }
        case let (.object(a), .object(b)):
            let leftKeys = Set(a.keys)
            guard leftKeys == Set(b.keys) else { return false }
            return leftKeys.allSatisfy { key in
                guard let left = a[key], let right = b[key] else { return false }
                return left.isSemanticallyEqual(to: right)
            }
        default:
            return false
        }
    }

    /// Digits in the mantissa, without sign, point, exponent or leading zeros.
    private static func significantDigits(_ literal: String) -> Int {
        let mantissa = literal.prefix { $0 != "e" && $0 != "E" }
        return mantissa.filter(\.isWholeNumber).drop { $0 == "0" }.count
    }
}

public nonisolated extension LosslessJSON {
    /// `self` with object members reordered to follow `reference`'s key order:
    /// keys `reference` has come first, in its order; new keys follow in their own
    /// order. Applied recursively (array elements by position), so rewriting a
    /// value keeps the diff to what actually changed.
    func aligned(to reference: LosslessJSON) -> LosslessJSON {
        switch (self, reference) {
        case let (.object(object), .object(referenceObject)):
            var members: [LosslessJSON.Object.Member] = []
            var remaining = object.members
            for key in referenceObject.keys {
                guard let index = remaining.firstIndex(where: { $0.key == key }) else { continue }
                var member = remaining.remove(at: index)
                if let referenceValue = referenceObject[key] { member.value = member.value.aligned(to: referenceValue) }
                members.append(member)
            }
            return .object(LosslessJSON.Object(members + remaining))
        case let (.array(array), .array(referenceArray)):
            return .array(array.enumerated().map { index, element in
                referenceArray.indices.contains(index) ? element.aligned(to: referenceArray[index]) : element
            })
        default:
            return self
        }
    }
}
