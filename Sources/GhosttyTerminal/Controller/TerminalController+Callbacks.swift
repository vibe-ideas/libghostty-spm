//
//  TerminalController+Callbacks.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// System pasteboard access and libghostty request completion used by
/// the clipboard callbacks. Injectable so tests can verify the security
/// contract — escalated requests must never complete with clipboard
/// data — without a live surface.
enum TerminalClipboardIO {
    nonisolated(unsafe) static var readString: () -> String? = {
        #if canImport(UIKit)
            UIPasteboard.general.string
        #elseif canImport(AppKit)
            TerminalPasteboard.string(from: .general)
        #endif
    }

    nonisolated(unsafe) static var writeString: (String) -> Void = { string in
        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    nonisolated(unsafe) static var complete: (
        _ surface: ghostty_surface_t,
        _ string: String,
        _ state: UnsafeMutableRawPointer,
        _ confirmed: Bool
    ) -> Void = { surface, string, state, confirmed in
        string.withCString { data in
            "text/plain".withCString { mime in
                var content = ghostty_clipboard_content_s(mime: mime, data: data, len: string.utf8.count)
                withUnsafePointer(to: &content) { contents in
                    var payload = ghostty_clipboard_complete_s(
                        contents: contents, contents_len: 1, available: nil, available_len: 0,
                        confirmed: confirmed, remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &payload, state)
                }
            }
        }
    }

    nonisolated(unsafe) static var deny: (ghostty_surface_t, UnsafeMutableRawPointer) -> Void = {
        ghostty_surface_deny_clipboard_request($0, $1)
    }
}

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()
        return terminalRunOnMainSync {
            bridge.handleAction(action)
        }
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm: Bool
    ) {
        // `confirm` is set when configuration (`clipboard-write = ask`)
        // requires a user decision before the pasteboard changes. This
        // bridge has no confirmation UI, so deny the write rather than
        // silently performing it.
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD, !confirm else {
            TerminalDebugLog.log(
                .input,
                "clipboard write denied: confirmation required but no UI exists"
            )
            return
        }
        guard let contents, contentsLen > 0 else { return }
        for content in UnsafeBufferPointer(start: contents, count: contentsLen) {
            guard let mime = content.mime else { continue }
            let type = String(cString: mime)
            guard type == "text/plain" || type.hasPrefix("text/plain;") else { continue }
            guard let data = content.data else { continue }
            let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
            TerminalClipboardIO.writeString(String(decoding: UnsafeBufferPointer(start: bytes, count: content.len), as: UTF8.self))
            return
        }
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        listAvailable: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard clipboard == GHOSTTY_CLIPBOARD_STANDARD,
              let userdata, let opaquePtr else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        if let mimes, mimesLen > 0 {
            let types = UnsafeBufferPointer(start: mimes, count: mimesLen).compactMap { $0.map { String(cString: $0) } }
            guard types.contains(where: { $0 == "text/plain" || $0.hasPrefix("text/plain;") }) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
        }
        // The host currently exposes text only. Do not retrieve clipboard
        // contents in response to a MIME-list-only request.
        if listAvailable && mimesLen == 0 {
            var payload = ghostty_clipboard_complete_s()
            ghostty_surface_complete_clipboard_request(surface, &payload, opaquePtr)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        guard let string = TerminalClipboardIO.readString() else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        TerminalDebugLog.log(
            .input,
            "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
        )
        // Complete unconfirmed: Ghostty re-checks configuration and
        // escalates to confirmReadClipboard when a user decision is
        // required (unsafe paste, `clipboard-read = ask`).
        TerminalClipboardIO.complete(surface, string, opaquePtr, false)
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty escalates a clipboard request here when configuration
    /// demands a user decision: `clipboard-read = ask` for an OSC 52
    /// read, or paste protection for an unsafe paste. The request is
    /// routed to the surface delegate, which presents a prompt and
    /// resolves it; without a confirmation delegate it is denied (see
    /// ``TerminalCallbackBridge/handleClipboardConfirmation``).
    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let confirm, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        // OSC 52 writes never escalate through this callback (the write
        // callback's `confirm` flag covers them), and completing one
        // would push text onto the system pasteboard.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE || request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
            if let surface = bridge.rawSurface { TerminalClipboardIO.deny(surface, opaquePtr) }
            return
        }

        let kind: TerminalClipboardConfirmationRequest.Kind =
            request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? .unsafePaste : .osc52Read
        // Copy out of the C buffer before hopping threads: the string
        // pointer is only valid for the duration of this callback,
        // while the decision may arrive much later. The request state
        // pointer stays valid until the request is completed.
        let payload = confirm.pointee
        let representations = payload.contents.map { UnsafeBufferPointer(start: $0, count: payload.contents_len) }
        let text = representations?.first(where: {
            guard let mime = $0.mime else { return false }
            let type = String(cString: mime)
            return type == "text/plain" || type.hasPrefix("text/plain;")
        })
        let contents = text.flatMap { content -> String? in
            guard let data = content.data else { return nil }
            let bytes = UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self)
            return String(decoding: UnsafeBufferPointer(start: bytes, count: content.len), as: UTF8.self)
        } ?? ""
        let stateBits = UInt(bitPattern: opaquePtr)
        terminalRunOnMain {
            guard let state = UnsafeMutableRawPointer(bitPattern: stateBits) else {
                return
            }
            bridge.handleClipboardConfirmation(
                contents: contents,
                kind: kind,
                state: state
            )
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    listAvailable: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLen: mimesLen,
        listAvailable: listAvailable
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirm: confirm,
        opaquePtr: opaquePtr,
        request: request
    )
}
