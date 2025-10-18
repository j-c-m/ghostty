import Foundation
import Cocoa


@objc(GhosttyScriptNewWindowCommand)
class ScriptNewWindowCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        print("ScriptNewWindowCommand called")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            var config: Ghostty.SurfaceConfiguration? = nil
            if let command = evaluatedArguments?["command"] as? String {
                config = Ghostty.SurfaceConfiguration()
                let wait = evaluatedArguments?["wait"] as? Bool ?? false
                if wait {
                    // Use command-based approach (forces waiting)
                    config?.command = command
                    config?.waitAfterCommand = true
                } else {
                    // Use initialInput approach (no waiting)
                    config?.initialInput = "\(command); exit\n"
                    config?.waitAfterCommand = false
                }
            }
            _ = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
        }
        return nil
    }
}

@objc(GhosttyScriptNewTabCommand)
class ScriptNewTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        print("ScriptNewTabCommand called")
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            var config: Ghostty.SurfaceConfiguration? = nil
            if let command = evaluatedArguments?["command"] as? String {
                config = Ghostty.SurfaceConfiguration()
                let wait = evaluatedArguments?["wait"] as? Bool ?? false
                if wait {
                    // Use command-based approach (forces waiting)
                    config?.command = command
                    config?.waitAfterCommand = true
                } else {
                    // Use initialInput approach (no waiting)
                    config?.initialInput = "\(command); exit\n"
                    config?.waitAfterCommand = false
                }
            }
            _ = TerminalController.newTab(
                appDelegate.ghostty,
                from: TerminalController.preferredParent?.window,
                withBaseConfig: config
            )
        }
        return nil
    }
}
