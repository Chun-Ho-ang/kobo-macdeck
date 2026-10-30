// ChatGPT / Claude App 的視窗：讀標題與「正在回答」，或按下一個指定名稱的按鈕 / 選單項目
// 包成「MacDeck Windows.app」用 open 啟動，輔助使用權限算在這個 App 自己身上
// 用法：
//   app-windows <輸出檔> [--dump]                        讀兩個 App 的狀態（--dump 列出按鈕名稱）
//   app-windows <輸出檔> --press <bundle id> <名稱>...    按下第一個符合的按鈕或選單項目（名稱依序優先）
// 要按哪些名稱由 Companion 決定（macdeck_companion/actions.py），這裡只負責找到並按下
import AppKit
import ApplicationServices

let apps = ["com.openai.codex", "com.anthropic.claudefordesktop"]
let args = CommandLine.arguments
let dump = args.contains("--dump")

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    if args.count > 1, !args[1].hasPrefix("--") {
        try? data.write(to: URL(fileURLWithPath: args[1]), options: .atomic)
    } else {
        print(String(data: data, encoding: .utf8)!)
    }
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func label(_ el: AXUIElement) -> String? {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
        if let s = attr(el, key) as? String, !s.isEmpty { return s }
    }
    return nil
}

func appRoot(_ bundle: String) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    // 網頁技術做的 App 要先開這兩個旗標，才會把畫面內容放進輔助使用樹（第一次開啟後要等一下才建好）
    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    return root
}

/// 廣度優先走樹，收集指定角色的元素（數量有上限，避免大視窗跑太久）
func collect(_ roots: [AXUIElement], roles: Set<String>, limit: Int = 6000) -> (items: [(String, AXUIElement)], visited: Int) {
    var queue: [(AXUIElement, Int)] = roots.map { ($0, 0) }
    var out: [(String, AXUIElement)] = []
    var visited = 0
    while !queue.isEmpty, visited < limit {
        let (el, depth) = queue.removeFirst()
        visited += 1
        if let role = attr(el, kAXRoleAttribute) as? String, roles.contains(role), let name = label(el) {
            out.append((name, el))
        }
        if depth < 60, let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            queue += kids.map { ($0, depth + 1) }
        }
    }
    return (out, visited)
}

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard trusted else {
    emit(["error": "Allow Accessibility for MacDeck Windows"])
    exit(0)
}

// ── 按下按鈕 / 選單項目 ──
if let i = args.firstIndex(of: "--press"), args.count > i + 2 {
    let bundle = args[i + 1]
    let wanted = Array(args[(i + 2)...])
    guard let root = appRoot(bundle) else {
        emit(["error": "app not running"])
        exit(0)
    }
    var roots = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let bar = attr(root, kAXMenuBarAttribute) { roots.append(bar as! AXUIElement) }
    let found = collect(roots, roles: [kAXButtonRole, kAXMenuItemRole, kAXRadioButtonRole]).items
        .filter { (attr($0.1, kAXEnabledAttribute) as? Bool) ?? true }
    // 依名稱的先後順序找：先完全相同，再找開頭相同（例如「Start Dictation…」）
    for w in wanted {
        let lw = w.lowercased()
        let hit = found.first { $0.0.lowercased() == lw } ?? found.first { $0.0.lowercased().hasPrefix(lw) }
        if let (name, el) = hit, AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            emit(["pressed": name])
            exit(0)
        }
    }
    emit(["pressed": NSNull(), "buttons": Array((Array(NSOrderedSet(array: found.map { $0.0 })) as! [String]).prefix(80))])
    exit(0)
}

// ── 讀狀態 ──
var result: [String: Any] = [:]
for bundle in apps {
    guard let root = appRoot(bundle) else { continue }
    var titles: [String] = []
    let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for w in windows {
        if let t = attr(w, kAXTitleAttribute) as? String, !t.isEmpty { titles.append(t) }
    }
    let (items, visited) = collect(windows, roles: [kAXButtonRole])
    let unique = Array(NSOrderedSet(array: items.map { $0.0 })) as! [String]
    // 「正在回答」：畫面上有短的 Stop / 停止 按鈕（排除像 Stop sharing 這類長名稱）
    let stop = unique.contains { b in
        let l = b.lowercased()
        return (l == "stop" || l.hasPrefix("stop generating") || l.hasPrefix("stop response")
            || l.hasPrefix("stop streaming") || b.hasPrefix("停止")) && b.count <= 24
    }
    // 目前對話的名稱常出現在「<名稱>, rename …」按鈕上（視窗標題只是 App 名稱時用得到）
    let renames = unique.compactMap { b -> String? in
        guard let r = b.range(of: ", rename", options: .caseInsensitive) else { return nil }
        return String(b[..<r.lowerBound])
    }
    var info: [String: Any] = ["windows": titles, "answering": stop, "conversation": renames.first ?? "",
                               "visited": visited, "button_count": unique.count]
    if dump { info["buttons"] = Array(unique.prefix(120)) }
    result[bundle] = info
}
emit(["apps": result])
