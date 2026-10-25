import CoreFoundation
import Foundation
import OrbitCore

/// macOS preferences (what `defaults` reads and writes), with their exact types kept.
public enum Preferences {
    static func domain(_ name: String) -> CFString {
        name == WatchedPreferences.globalDomain ? kCFPreferencesAnyApplication : name as CFString
    }

    public static func read(_ domainName: String, _ key: String) -> PrefValue? {
        reading { $0(domainName, key) }
    }

    /// Reads several keys, bringing each domain up to date once (each time asks macOS's preferences
    /// service) rather than once per key.
    public static func reading<T>(_ body: (_ read: (_ domain: String, _ key: String) -> PrefValue?) -> T) -> T {
        var synced = Set<String>()
        return body { domainName, key in
            let cfDomain = domain(domainName)
            if synced.insert(domainName).inserted { CFPreferencesAppSynchronize(cfDomain) }
            return CFPreferencesCopyAppValue(key as CFString, cfDomain).flatMap(value)
        }
    }

    public static func value(_ plist: CFPropertyList) -> PrefValue? {
        let type = CFGetTypeID(plist)
        if type == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((plist as! CFBoolean))) }
        if type == CFNumberGetTypeID() {
            let number = plist as! NSNumber
            return CFNumberIsFloatType((plist as! CFNumber)) ? .double(number.doubleValue) : .int(number.intValue)
        }
        if type == CFStringGetTypeID() { return .string(plist as! String) }
        if type == CFDataGetTypeID() { return .data(plist as! Data) }
        if type == CFDateGetTypeID() { return .date(plist as! Date) }
        if type == CFArrayGetTypeID() {
            return .array((plist as! [AnyObject]).compactMap { value($0 as CFPropertyList) })
        }
        if type == CFDictionaryGetTypeID() {
            var out: [String: PrefValue] = [:]
            for (key, item) in plist as! [String: AnyObject] {
                if let v = value(item as CFPropertyList) { out[key] = v }
            }
            return .dict(out)
        }
        return nil
    }

    public static func plist(_ value: PrefValue) -> CFPropertyList {
        switch value {
        case .bool(let b): return b as CFBoolean
        case .int(let i): return i as NSNumber
        case .double(let d): return d as NSNumber
        case .string(let s): return s as CFString
        case .data(let d): return d as CFData
        case .date(let d): return d as CFDate
        case .array(let items): return items.map(plist) as CFArray
        case .dict(let items): return items.mapValues(plist) as CFDictionary
        }
    }
}

public extension PrefValue {
    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var arrayValue: [PrefValue]? { if case .array(let a) = self { a } else { nil } }
    var dictValue: [String: PrefValue]? { if case .dict(let d) = self { d } else { nil } }
}

public protocol PreferenceWriting: Sendable {
    /// Sets a preference, or removes it when `value` is nil.
    func set(_ domain: String, _ key: String, _ value: PrefValue?)
}

public struct LivePreferences: PreferenceWriting {
    public init() {}

    public func set(_ domainName: String, _ key: String, _ value: PrefValue?) {
        let cfDomain = Preferences.domain(domainName)
        CFPreferencesSetAppValue(key as CFString, value.map(Preferences.plist), cfDomain)
        CFPreferencesAppSynchronize(cfDomain)
    }
}

public struct PracticePreferences: PreferenceWriting {
    let log: PracticeLog

    public init(log: PracticeLog) { self.log = log }

    public func set(_ domain: String, _ key: String, _ value: PrefValue?) {
        log.record("Would change the setting \(key)", "\(domain) \(key) = \(value.map { "\($0)" } ?? "(removed)")")
    }
}
