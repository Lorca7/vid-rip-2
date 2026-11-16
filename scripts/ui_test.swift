// Drives a running VidRip with the real mouse and checks the editor reacts correctly.
// VidRip must be running with `--ui-probe <probe.json>` and a video open.
// Usage: swift scripts/ui_test.swift <probe.json>
import CoreGraphics
import Foundation

let probeURL = URL(fileURLWithPath: CommandLine.arguments[1])
var failures = 0

struct Snapshot {
    let points: [String: CGRect]
    let state: [String: Any]

    func number(_ key: String) -> Double { (state[key] as? NSNumber)?.doubleValue ?? .nan }
    var crop: CGRect {
        let v = (state["crop"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}

func snapshot() -> Snapshot? {
    guard let data = try? Data(contentsOf: probeURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var points: [String: CGRect] = [:]
    for (name, value) in (json["points"] as? [String: [Double]]) ?? [:] where value.count == 4 {
        points[name] = CGRect(x: value[0], y: value[1], width: value[2], height: value[3])
    }
    return Snapshot(points: points, state: json["state"] as? [String: Any] ?? [:])
}

func waitFor(_ what: String, timeout: TimeInterval = 60, _ condition: (Snapshot) -> Bool) -> Snapshot {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let snap = snapshot(), condition(snap) { return snap }
        usleep(250_000)
    }
    print("❌ Timed out waiting for \(what)")
    if let snap = snapshot() { print("   last probe: \(snap.points.keys.sorted()) \(snap.state)") }
    exit(1)
}

func settle() -> Snapshot {
    usleep(700_000)
    return snapshot()!
}

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(25_000)
}

func click(_ point: CGPoint) {
    post(.mouseMoved, point)
    post(.leftMouseDown, point)
    post(.leftMouseUp, point)
}

func drag(_ from: CGPoint, _ to: CGPoint) {
    post(.mouseMoved, from)
    post(.leftMouseDown, from)
    for step in 1...20 {
        let t = CGFloat(step) / 20
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    }
    post(.leftMouseUp, to)
}

func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "✅" : "❌") \(name) — \(detail)")
    if !ok { failures += 1 }
}

func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
func f(_ v: Double) -> String { String(format: "%.2f", v) }

// Wait for the editor.
var snap = waitFor("the editor to load") { s in
    (s.state["ready"] as? Bool) == true && ["track", "leftHandle", "rightHandle", "selection", "cropToggle"].allSatisfy { s.points[$0] != nil }
}
let duration = snap.number("duration")
let track = snap.points["track"]!
let pad = 14.0
let usable = Double(track.width) - pad * 2
let stripY = track.minY + track.height * 0.6
func timeAt(_ x: CGFloat) -> Double { duration * min(max((Double(x - track.minX) - pad) / usable, 0), 1) }
print("Editor ready: duration \(f(duration))s, timeline \(Int(track.width))pt wide at \(Int(track.minX)),\(Int(track.minY))")

// Bring the window forward with a harmless click on the timeline.
click(CGPoint(x: track.minX + track.width * 0.9, y: stripY))
snap = settle()

// 1. Click on the timeline places the playhead.
let clickX = track.minX + track.width * 0.3
click(CGPoint(x: clickX, y: stripY))
snap = settle()
check("Click timeline to place playhead", abs(snap.number("current") - timeAt(clickX)) < duration * 0.02,
      "expected ≈\(f(timeAt(clickX)))s, playhead at \(f(snap.number("current")))s")

// 2. Drag the left handle to the right.
var before = snap
drag(center(before.points["leftHandle"]!), center(before.points["leftHandle"]!).applying(.init(translationX: 100, y: 0)))
snap = settle()
check("Drag left handle", snap.number("in") > before.number("in") + duration * 0.02 && abs(snap.number("out") - before.number("out")) < 0.05,
      "start \(f(before.number("in")))→\(f(snap.number("in")))s, end \(f(before.number("out")))→\(f(snap.number("out")))s")

// 3. Drag the window body to the left; its length must stay the same.
before = snap
let length = before.number("out") - before.number("in")
drag(center(before.points["selection"]!), center(before.points["selection"]!).applying(.init(translationX: -80, y: 0)))
snap = settle()
let newLength = snap.number("out") - snap.number("in")
check("Move whole window", snap.number("in") < before.number("in") - duration * 0.02 && abs(newLength - length) < 0.05,
      "start \(f(before.number("in")))→\(f(snap.number("in")))s, length \(f(length))→\(f(newLength))s")

// 4. Drag the right handle to the right.
before = snap
drag(center(before.points["rightHandle"]!), center(before.points["rightHandle"]!).applying(.init(translationX: 60, y: 0)))
snap = settle()
check("Drag right handle", snap.number("out") > before.number("out") + duration * 0.02 && abs(snap.number("in") - before.number("in")) < 0.05,
      "end \(f(before.number("out")))→\(f(snap.number("out")))s, start \(f(before.number("in")))→\(f(snap.number("in")))s")

// 5. Click inside the window places the playhead there (without moving the window).
before = snap
let inside = before.points["selection"]!
let insideX = inside.minX + inside.width * 0.7
click(CGPoint(x: insideX, y: stripY))
snap = settle()
check("Click inside window to place playhead",
      abs(snap.number("current") - timeAt(insideX)) < duration * 0.02 && abs(snap.number("in") - before.number("in")) < 0.05,
      "expected ≈\(f(timeAt(insideX)))s, playhead at \(f(snap.number("current")))s")

// 6. Crop: turn it on.
click(center(snap.points["cropToggle"]!))
snap = waitFor("the crop window", timeout: 10) { s in
    (s.state["cropEnabled"] as? Bool) == true && s.points["cropRect"] != nil && s.points["cropHandle.bottomRight"] != nil && s.points["video"] != nil
}
usleep(500_000)
snap = snapshot()!
check("Crop window appears", snap.crop.width > 0, "crop \(snap.crop)")

// 7. Resize from the bottom-right corner.
before = snap
let corner = center(before.points["cropHandle.bottomRight"]!)
drag(corner, CGPoint(x: corner.x - 120, y: corner.y - 70))
snap = settle()
check("Resize crop from corner", snap.crop.width < before.crop.width - 20 && snap.crop.height < before.crop.height - 20 && abs(snap.crop.minX - before.crop.minX) < 2,
      "\(before.crop.size) → \(snap.crop.size)")

// 8. Move the crop window.
before = snap
drag(center(before.points["cropRect"]!), center(before.points["cropRect"]!).applying(.init(translationX: 50, y: 30)))
snap = settle()
check("Move crop window", snap.crop.minX > before.crop.minX + 10 && snap.crop.minY > before.crop.minY + 10 && abs(snap.crop.width - before.crop.width) < 2,
      "origin \(before.crop.origin) → \(snap.crop.origin), size \(before.crop.size) → \(snap.crop.size)")

// 9. Draw a new crop area by dragging on the picture outside the window.
before = snap
let video = before.points["video"]!
let from = CGPoint(x: video.minX + 6, y: video.minY + 6)
let to = CGPoint(x: video.minX + video.width * 0.4, y: video.minY + video.height * 0.4)
drag(from, to)
snap = settle()
let videoPixels = (snap.state["video"] as? [NSNumber])?.map(\.doubleValue) ?? [1, 1]
let expectedWidth = videoPixels[0] * Double((to.x - from.x) / video.width)
check("Draw new crop area", snap.crop.minX < before.crop.minX && abs(Double(snap.crop.width) - expectedWidth) < videoPixels[0] * 0.05,
      "new crop \(snap.crop), expected width ≈\(Int(expectedWidth))")

print(failures == 0 ? "All mouse tests passed." : "\(failures) mouse test(s) failed.")
exit(failures == 0 ? 0 : 1)
