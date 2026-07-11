//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {
    final class TouchContext {
        fileprivate var tid: Int?
        fileprivate weak var keyWindow: UIWindow?
        fileprivate weak var keyView: UIView?

        var isActive: Bool {
            tid != nil
        }
    }

    static weak var keyWindow: UIWindow?
    static weak var keyView: UIView?
    // For debug only
    static var logEnabled = false
    static var logFilePath =
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/toucher.log"
    static private var logCount = 0
    static var logFile: FileHandle?

    private static func unityView(containing view: UIView?) -> UIView? {
        var current = view
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className == "UnityView" || className.hasSuffix(".UnityView") {
                return view
            }
            current = view.superview
        }
        return nil
    }

    private static func touchView(at point: CGPoint, in window: UIWindow?) -> UIView? {
        let hitView = window?.hitTest(point, with: nil)
        return unityView(containing: hitView) ?? hitView
    }

    /**
     on invocations with phase "began", an int id is allocated, which can be used later to refer to this touch point.
     on invocations with phase "ended", id is set to nil representing the touch point is no longer valid.
     */
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?,
                         // Name info for debug use
                         actionName: String, keyName: String) {
        if phase == UITouch.Phase.began && tid == nil {
            keyWindow = screen.keyWindow
            keyView = touchView(at: point, in: keyWindow)
        }
        dispatchTouch(point: point, phase: phase, tid: &tid,
                      keyWindow: keyWindow, keyView: keyView,
                      actionName: actionName, keyName: keyName)
    }

    static func touchcam(point: CGPoint, phase: UITouch.Phase, context: TouchContext,
                         // Name info for debug use
                         actionName: String, keyName: String) {
        if phase == UITouch.Phase.began && !context.isActive {
            context.keyWindow = screen.keyWindow
            context.keyView = touchView(at: point, in: context.keyWindow)
        }
        dispatchTouch(point: point, phase: phase, tid: &context.tid,
                      keyWindow: context.keyWindow, keyView: context.keyView,
                      actionName: actionName, keyName: keyName)
        if !context.isActive {
            context.keyWindow = nil
            context.keyView = nil
        }
    }

    private static func dispatchTouch(point: CGPoint, phase: UITouch.Phase, tid: inout Int?,
                                      keyWindow: UIWindow?, keyView: UIView?,
                                      actionName: String, keyName: String) {
        if phase == UITouch.Phase.began {
            if tid != nil {
                return
            }
            tid = -1
        } else if tid == nil {
            return
        }
        var recordId = tid!
        tid = PTFakeMetaTouch.fakeTouchId(tid!, at: point, with: phase, in: keyWindow, on: keyView)
        writeLog(logMessage:
                "\(phase.rawValue.description) \(tid!.description) \(point.debugDescription)")
        if tid! < 0 {
            tid = nil
        } else {
            recordId = tid!
        }
        DebugModel.instance.record(point: point, phase: phase, tid: recordId,
                                   description: actionName + "(" + keyName + ")")
    }

    static func setupLogfile() {
        if FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil) {
            logFile = FileHandle(forWritingAtPath: logFilePath)
            Toast.showOver(msg: logFilePath)
        } else {
            Toast.showHint(title: "logFile creation failed")
            return
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { _ in
            try? logFile?.close()
        }
    }

    static func writeLog(logMessage: String) {
        if !logEnabled {
            return
        }
        guard let file = logFile else {
            setupLogfile()
            return
        }
        let message = "\(DispatchTime.now().rawValue) \(logMessage)\n"
        guard let data = message.data(using: .utf8) else {
            Toast.showHint(title: "log message is utf8 uncodable")
            return
        }
        logCount += 1
        // roll over
        if logCount > 60000 {
            file.seek(toFileOffset: 0)
            logCount = 0
        }
        file.write(data)
    }
}
