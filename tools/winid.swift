// Prints the window numbers of on-screen Frontier windows (tallest first is
// not guaranteed — first printed is usually the frontmost). Feed the number to
// `screencapture -x -o -l<id> out.png` to photograph a window even when
// something covers it. Run with `swift winid.swift`. Swap the owner check to
// photograph another app's windows.
import CoreGraphics
import Foundation
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in info {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("Frontier"),
          let num = w[kCGWindowNumber as String] as? Int,
          let bounds = w[kCGWindowBounds as String] as? [String: Any],
          (bounds["Height"] as? Double ?? 0) > 100 else { continue }
    print(num)
}
