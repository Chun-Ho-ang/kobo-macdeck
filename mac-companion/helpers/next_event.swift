// 接下來 7 天內最近的兩個行程（JSON），給 MacDeck Companion 用
// 全天行程、已取消、你已婉拒的會議不算
// 包成「MacDeck Calendar.app」用 open 啟動：行事曆權限算在這個 App 自己身上，
// 不管 Companion 是從終端機、VS Code 還是別的地方啟動都能正常詢問
// 用法：next-event <輸出檔>（沒給就印到 stdout）
import EventKit
import Foundation

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    if CommandLine.arguments.count > 1 {
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    } else {
        print(String(data: data, encoding: .utf8)!)
    }
}

let store = EKEventStore()
let done = DispatchSemaphore(value: 0)
var granted = false
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; done.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; done.signal() }
}
done.wait()
guard granted else {
    emit(["error": "Allow Calendar for MacDeck Calendar"])
    exit(0)
}

let now = Date()
let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
    .filter { e in
        guard !e.isAllDay, e.endDate > now, e.status != .canceled else { return false }
        let me = e.attendees?.first { $0.isCurrentUser }
        return me?.participantStatus != .declined
    }
    .sorted { $0.startDate < $1.startDate }

emit(["events": events.prefix(2).map { e in [
    "title": e.title ?? "",
    "start": e.startDate.timeIntervalSince1970,
    "end": e.endDate.timeIntervalSince1970,
    "location": e.location ?? "",
] }])
