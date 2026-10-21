import Foundation

/// A stored notification, decoded but not yet interpreted.
public struct RawNotification: Sendable, Equatable {
    /// Stable identity: the request identifier (`req.iden`), else the record's UUID, else its row ID.
    public var key: String
    public var bundleIdentifier: String?
    public var deliveredAt: Date?
    public var title: String
    public var subtitle: String
    public var body: String
    public var category: String?
    public var identifier: String?
    /// The user info (`req.usda`): text and number values, as text.
    public var userInfo: [String: String]
    /// Every user-info key, including those whose values aren't text or numbers.
    public var userInfoKeys: Set<String>
    public var userInfoState: UserInfoState

    public enum UserInfoState: String, Sendable, Equatable, Codable {
        case decoded, missing, unreadable
    }

    public init(
        key: String, bundleIdentifier: String? = nil, deliveredAt: Date? = nil, title: String = "",
        subtitle: String = "", body: String = "", category: String? = nil, identifier: String? = nil,
        userInfo: [String: String] = [:], userInfoKeys: Set<String>? = nil, userInfoState: UserInfoState = .decoded
    ) {
        self.key = key
        self.bundleIdentifier = bundleIdentifier
        self.deliveredAt = deliveredAt
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.identifier = identifier
        self.userInfo = userInfo
        self.userInfoKeys = userInfoKeys ?? Set(userInfo.keys)
        self.userInfoState = userInfoState
    }
}

public enum RecordDecodeFailure: String, Error, Sendable, Equatable, Codable, CaseIterable {
    case noData, notPlist, noRequest
}

/// Decodes `record.data`: a binary plist `{app, date, req: {titl, body, iden, cate, usda, …}, uuid, …}`
/// whose `req.usda` is the notification's user info, archived with NSKeyedArchiver.
public enum RecordDecoder {
    /// Plist classes only: anything else in an archive fails to decode instead of being instantiated.
    private static let archiveClasses: [AnyClass] = [
        NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self,
    ]

    public static func decode(_ record: StoredRecord) -> Result<RawNotification, RecordDecodeFailure> {
        guard let data = record.data, !data.isEmpty else { return .failure(.noData) }
        guard let plist = propertyList(data) as? [String: Any] else { return .failure(.notPlist) }
        guard let request = plist["req"] as? [String: Any] else { return .failure(.noRequest) }

        let identifier = (request["iden"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let uuid = record.uuid.flatMap { $0.isEmpty ? nil : $0 } ?? (plist["uuid"] as? Data)
        let key = identifier ?? uuid.map { $0.map { String(format: "%02x", $0) }.joined() }
            ?? record.recordID.map { "rec\($0)" } ?? "record"

        var info: [String: String] = [:]
        var keys = Set<String>()
        var state = RawNotification.UserInfoState.missing
        if let value = request["usda"] {
            if let dictionary = userInfo(value) {
                state = .decoded
                for (name, item) in dictionary {
                    keys.insert(name)
                    if let text = scalarText(item) { info[name] = text }
                }
            } else {
                state = .unreadable
            }
        }

        return .success(RawNotification(
            key: key,
            bundleIdentifier: plist["app"] as? String,
            deliveredAt: record.deliveredDate ?? date(plist["date"]) ?? record.requestDate,
            title: request["titl"] as? String ?? "",
            subtitle: request["subt"] as? String ?? "",
            body: request["body"] as? String ?? "",
            category: request["cate"] as? String,
            identifier: identifier,
            userInfo: info,
            userInfoKeys: keys,
            userInfoState: state
        ))
    }

    /// A plist, unpacking it when it's an NSKeyedArchiver archive.
    static func propertyList(_ data: Data) -> Any? {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        if let dictionary = value as? [String: Any], dictionary["$archiver"] as? String == "NSKeyedArchiver" {
            return try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archiveClasses, from: data)
        }
        return value
    }

    /// The user info dictionary, from archived bytes or an inline dictionary, unwrapping a `root` entry.
    private static func userInfo(_ value: Any) -> [String: Any]? {
        var decoded: Any? = value
        if let data = value as? Data {
            decoded = propertyList(data)
        }
        guard var dictionary = decoded as? [String: Any] else { return nil }
        if dictionary.count == 1, let root = dictionary["root"] as? [String: Any] {
            dictionary = root
        }
        return dictionary
    }

    private static func scalarText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? Double { return Date(timeIntervalSinceReferenceDate: seconds) }
        if let number = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: number.doubleValue) }
        return nil
    }
}
