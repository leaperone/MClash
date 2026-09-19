import ApplicationServices
import Foundation

enum ControlError: Error { case arguments, permission, screenLocked, windowMissing, elementMissing, actionFailed }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func find(_ root: AXUIElement, identifier: String) -> AXUIElement? {
    var pending = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [root]
    var index = 0
    var visited: Set<AXUIElement> = []
    var identifiers: [String] = []
    while index < pending.count, index < 5_000 {
        let current = pending[index]
        index += 1
        guard visited.insert(current).inserted else { continue }
        let role = attribute(current, kAXRoleAttribute) as? String
        if role == kAXMenuBarRole || role == kAXMenuRole || role == kAXMenuItemRole { continue }
        if let value = attribute(current, kAXIdentifierAttribute) as? String {
            identifiers.append(value)
            if value == identifier { return current }
        }
        if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
            pending.append(contentsOf: children)
        }
    }
    fputs("AX search inspected \(visited.count) unique elements; window count \((attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.count ?? -1); identifiers \(Array(identifiers.prefix(30)))\n", stderr)
    return nil
}

func run() throws {
    let arguments = CommandLine.arguments
    guard AXIsProcessTrusted() else { throw ControlError.permission }
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard session?["CGSSessionScreenIsLocked"] as? Bool != true else { throw ControlError.screenLocked }
    if arguments.count == 2, arguments[1] == "--check-session" { return }
    guard arguments.count >= 4, let pid = Int32(arguments[1]), pid > 0 else { throw ControlError.arguments }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 3)
    let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    guard !windows.isEmpty else { throw ControlError.windowMissing }
    guard let element = find(application, identifier: arguments[3]) else { throw ControlError.elementMissing }
    switch arguments[2] {
    case "press":
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw ControlError.actionFailed }
    case "set":
        guard arguments.count == 5 else { throw ControlError.arguments }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, arguments[4] as CFString) == .success else {
            throw ControlError.actionFailed
        }
    case "type":
        guard arguments.count == 5,
              AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw ControlError.actionFailed
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
            for pressed in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
                event?.flags = flags
                event?.postToPid(pid)
            }
        }
        key(0, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.1)
        let characters = Array(arguments[4].utf16)
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: pressed)
            characters.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                }
            }
            event?.postToPid(pid)
        }
        Thread.sleep(forTimeInterval: 0.1)
        key(48)
    case "enabled":
        print((attribute(element, kAXEnabledAttribute) as? Bool) == true ? "true" : "false")
    case "exists":
        print("true")
    case "select-first":
        guard let rows = attribute(element, kAXRowsAttribute) as? [AXUIElement], let first = rows.first,
              AXUIElementSetAttributeValue(first, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success else {
            throw ControlError.actionFailed
        }
    default:
        throw ControlError.arguments
    }
}

do { try run() } catch {
    fputs("Isolated application UI control failed: \(error)\n", stderr)
    exit(1)
}
