import AppKit
import Foundation
import SwiftUI

/// Opens a prefilled GitHub issue on the Yap repository. System info is also copied to the clipboard in case the body is truncated.
@MainActor
struct EmailSupport {
    static func generateSupportEmailBody() -> String {
        let systemInfo = SystemInfoService.shared.getSystemInfoString()

        return """
            **What happened**


            **What you expected**


            **Steps to reproduce**


            <details><summary>System information</summary>

            ```
            \(systemInfo)
            ```
            </details>
            """
    }

    static func openSupportEmail() {
        SystemInfoService.shared.copySystemInfoToClipboard()

        var components = URLComponents(url: AppIdentity.issuesURL.appendingPathComponent("new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "body", value: generateSupportEmailBody())]
        NSWorkspace.shared.open(components?.url ?? AppIdentity.issuesURL)
    }
}
