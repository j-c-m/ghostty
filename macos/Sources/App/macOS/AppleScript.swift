import Foundation
import Cocoa

@objc(GhosttyScriptNewWindowCommand)
class ScriptNewWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        print("ScriptNewWindowCommand called")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            _ = TerminalController.newWindow(appDelegate.ghostty)
        }
        return nil
    }
}

@objc(GhosttyScriptNewTabCommand)
class ScriptNewTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        print("ScriptNewTabCommand called")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            _ = TerminalController.newTab(
                appDelegate.ghostty,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: nil
            )
        }
        return nil
    }
}
