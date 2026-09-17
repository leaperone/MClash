import ApplicationServices
import Foundation

enum ControlError: Error { case arguments, permission, elementMissing, actionFailed }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func find(_ root: AXUIElement, identifier: String) -> AXUIElement? {
    var pending = [root]
    var inspected = 0
    while let current = pending.popLast(), inspected < 5_000 {
        inspected += 1
        if attribute(current, kAXIdentifierAttribute) as? String == identifier { return current }
        if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
            pending.append(contentsOf: children)
        }
    }
    return nil
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 4, let pid = Int32(arguments[1]), pid > 0 else { throw ControlError.arguments }
    guard AXIsProcessTrusted() else { throw ControlError.permission }
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 3)
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
                event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
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
