import ApplicationServices
import Carbon  // IsSecureEventInputEnabled
import Foundation

struct AutoLearnAXTextReading {
    let appElement: AXUIElement
    let targetElement: AXUIElement
    let fieldText: String
    let selection: NSRange?
    let source: String
    let focusSource: String
}

struct AutoLearnAXTextValue {
    let text: String
    let source: String
}

/// What the focused element says about itself, read before its value is: enough to refuse a field that must not be read.
struct AutoLearnAXFieldDescription: Equatable {
    var role: String?
    var subrole: String?
    /// AXNumberOfCharacters, when the element reports it.
    var characterCount: Int?
}

struct AutoLearnAXFocusedText {
    let readings: [AutoLearnAXTextReading]
    /// Set when a focused element was refused before reading anything; `readings` is then empty.
    let exclusion: AutoLearnUnobservableReason?
}

/// Reads editable text through macOS Accessibility only. Web accessibility is
/// activated on demand; no keyboard event tap or Input Monitoring is involved.
final class AutoLearnAXTextReader {
    private struct MarkerSnapshot {
        let text: String
        let selection: NSRange
    }

    private static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let selectedMarkerRangeAttribute = "AXSelectedTextMarkerRange" as CFString
    private static let documentStartMarkerAttribute = "AXStartTextMarker" as CFString
    private static let documentEndMarkerAttribute = "AXEndTextMarker" as CFString
    private static let startMarkerForRangeAttribute = "AXStartTextMarkerForTextMarkerRange" as CFString
    private static let endMarkerForRangeAttribute = "AXEndTextMarkerForTextMarkerRange" as CFString
    private static let rangeForMarkersAttribute = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString
    private static let stringForMarkerRangeAttribute = "AXStringForTextMarkerRange" as CFString

    private var manualAccessibilityLastEnabledAt: [pid_t: UInt64] = [:]
    private var manualAccessibilityUnsupportedUntil: [pid_t: UInt64] = [:]
    private var manualAccessibilityPreviousValue: [pid_t: Bool] = [:]

    /// The focused editable field's text; empty for a password field or while secure input is on (focusedText).
    func focusedReadings(processID: pid_t) -> [AutoLearnAXTextReading] {
        focusedText(processID: processID).readings
    }

    /// The focused editable field's text. Every focused candidate is described before any value is read: while secure
    /// input is on, or if one of them is a password field, nothing is read from any of them; a field that's too long
    /// is skipped.
    func focusedText(processID: pid_t) -> AutoLearnAXFocusedText {
        if IsSecureEventInputEnabled() {
            return AutoLearnAXFocusedText(readings: [], exclusion: .secureInput)
        }
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(
            appElement,
            AutoLearnLimits.captureAccessibilityTimeoutSeconds
        )
        enableWebAccessibilityIfNeeded(processID: processID, appElement: appElement)

        var candidates: [(element: AXUIElement, source: String)] = []
        if let appFocused = copyElement(kAXFocusedUIElementAttribute as CFString, from: appElement) {
            appendUnique(appFocused, source: "application-focus", to: &candidates)
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let systemFocused = copyElement(kAXFocusedUIElementAttribute as CFString, from: systemWide),
            owningProcessID(of: systemFocused) == processID
        {
            appendUnique(systemFocused, source: "system-focus", to: &candidates)
        }

        let exclusions = candidates.map { Self.exclusion(for: describe($0.element), secureInputEnabled: false) }
        if exclusions.contains(.secureField) {
            restoreWebAccessibility(processID: processID, appElement: appElement)
            return AutoLearnAXFocusedText(readings: [], exclusion: .secureField)
        }

        var readings: [AutoLearnAXTextReading] = []
        var skippedTooLong = false
        for (candidate, exclusion) in zip(candidates, exclusions) {
            guard isEditable(candidate.element) else { continue }
            guard exclusion == nil else {
                skippedTooLong = true
                continue
            }

            let candidateReadings = makeReadings(
                from: candidate.element,
                appElement: appElement,
                focusSource: candidate.source
            )
            readings.append(contentsOf: candidateReadings)
        }
        if readings.isEmpty { restoreWebAccessibility(processID: processID, appElement: appElement) }
        return AutoLearnAXFocusedText(
            readings: readings, exclusion: readings.isEmpty && skippedTooLong ? .fieldTooLong : nil)
    }

    /// Why a field must not be read, from what it says about itself; nil when it may be. Secure input (system-wide,
    /// on while any password field has focus) refuses every field.
    static func exclusion(
        for field: AutoLearnAXFieldDescription, secureInputEnabled: Bool
    ) -> AutoLearnUnobservableReason? {
        if secureInputEnabled { return .secureInput }
        let secure = kAXSecureTextFieldSubrole as String
        if field.role == secure || field.subrole == secure { return .secureField }
        if let count = field.characterCount, count > AutoLearnLimits.maximumFieldUTF16Length { return .fieldTooLong }
        return nil
    }

    /// The same check for one element, for a read of a field found earlier (the end-of-observation snapshot).
    func exclusion(for element: AXUIElement) -> AutoLearnUnobservableReason? {
        Self.exclusion(for: describe(element), secureInputEnabled: IsSecureEventInputEnabled())
    }

    private func describe(_ element: AXUIElement) -> AutoLearnAXFieldDescription {
        AutoLearnAXFieldDescription(
            role: copyString(kAXRoleAttribute as CFString, from: element),
            subrole: copyString(kAXSubroleAttribute as CFString, from: element),
            characterCount: copyInteger(kAXNumberOfCharactersAttribute as CFString, from: element)
        )
    }

    func restoreWebAccessibility(processID: pid_t, appElement: AXUIElement) {
        guard let previous = manualAccessibilityPreviousValue.removeValue(forKey: processID) else { return }
        _ = AXUIElementSetAttributeValue(appElement, Self.manualAccessibilityAttribute, previous ? kCFBooleanTrue : kCFBooleanFalse)
        manualAccessibilityLastEnabledAt.removeValue(forKey: processID)
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        if let value = copyBool("AXEditable" as CFString, from: element) { return value }
        let role = copyString(kAXRoleAttribute as CFString, from: element) ?? ""
        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

    func textValue(from element: AXUIElement) -> AutoLearnAXTextValue? {
        let attributes = attributeNames(of: element)
        let parameterizedAttributes = parameterizedAttributeNames(of: element)

        if parameterizedAttributes.contains(kAXStringForRangeParameterizedAttribute as String),
            attributes.contains(kAXNumberOfCharactersAttribute as String),
            let documentLength = copyInteger(kAXNumberOfCharactersAttribute as CFString, from: element),
            documentLength >= 0,
            documentLength <= AutoLearnLimits.maximumFieldUTF16Length,
            let text = copyStringForRange(
                NSRange(location: 0, length: documentLength),
                from: element
            ),
            documentLength == 0 || !text.isEmpty
        {
            return AutoLearnAXTextValue(text: text, source: "string-for-range")
        }

        guard let value = copyString(kAXValueAttribute as CFString, from: element),
            value.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
        else {
            guard let markerSnapshot = markerSnapshot(from: element) else { return nil }
            return AutoLearnAXTextValue(text: markerSnapshot.text, source: "text-markers")
        }
        return AutoLearnAXTextValue(text: value, source: "value")
    }

    private func makeReadings(
        from element: AXUIElement,
        appElement: AXUIElement,
        focusSource: String
    ) -> [AutoLearnAXTextReading] {
        var result: [AutoLearnAXTextReading] = []

        if let textValue = textValue(from: element) {
            let reportedSelection = copyRange(
                kAXSelectedTextRangeAttribute as CFString,
                from: element
            )
            let selection = reportedSelection.flatMap {
                isValid($0, inUTF16Length: textValue.text.utf16.count) ? $0 : nil
            }
            result.append(
                AutoLearnAXTextReading(
                    appElement: appElement,
                    targetElement: element,
                    fieldText: textValue.text,
                    selection: selection,
                    source: "native-\(textValue.source)",
                    focusSource: focusSource
                )
            )
        }

        if let markerReading = markerReading(
            from: element,
            appElement: appElement,
            focusSource: focusSource
        ) {
            let isDuplicate = result.contains {
                $0.selection == markerReading.selection
                    && $0.fieldText.utf16.elementsEqual(markerReading.fieldText.utf16)
            }
            if !isDuplicate {
                result.append(markerReading)
            }
        }

        return result
    }

    private func markerReading(
        from element: AXUIElement,
        appElement: AXUIElement,
        focusSource: String
    ) -> AutoLearnAXTextReading? {
        guard let snapshot = markerSnapshot(from: element) else { return nil }
        return AutoLearnAXTextReading(
            appElement: appElement,
            targetElement: element,
            fieldText: snapshot.text,
            selection: snapshot.selection,
            source: "text-markers",
            focusSource: focusSource
        )
    }

    private func markerSnapshot(from element: AXUIElement) -> MarkerSnapshot? {
        let parameterizedAttributes = parameterizedAttributeNames(of: element)
        guard parameterizedAttributes.contains(Self.startMarkerForRangeAttribute as String),
            parameterizedAttributes.contains(Self.endMarkerForRangeAttribute as String),
            parameterizedAttributes.contains(Self.rangeForMarkersAttribute as String),
            parameterizedAttributes.contains(Self.stringForMarkerRangeAttribute as String),
            let selectedRange = copyOpaque(Self.selectedMarkerRangeAttribute, from: element),
            let documentStart = copyOpaque(Self.documentStartMarkerAttribute, from: element),
            let documentEnd = copyOpaque(Self.documentEndMarkerAttribute, from: element),
            let selectionStart = copyOpaqueParameterized(
                Self.startMarkerForRangeAttribute,
                parameter: selectedRange,
                from: element
            ),
            let selectionEnd = copyOpaqueParameterized(
                Self.endMarkerForRangeAttribute,
                parameter: selectedRange,
                from: element
            ),
            let beforeRange = markerRange(from: documentStart, to: selectionStart, on: element),
            let beforeText = stringForMarkerRange(beforeRange, on: element)
        else {
            return nil
        }

        guard let selectedText = stringForMarkerRange(selectedRange, on: element) else { return nil }
        let afterText: String
        if let afterRange = markerRange(from: selectionEnd, to: documentEnd, on: element),
            let text = stringForMarkerRange(afterRange, on: element)
        {
            afterText = text
        } else { return nil }

        let fieldText = beforeText + selectedText + afterText
        guard fieldText.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length else {
            return nil
        }

        return MarkerSnapshot(
            text: fieldText,
            selection: NSRange(
                location: beforeText.utf16.count,
                length: selectedText.utf16.count
            )
        )
    }

    private func enableWebAccessibilityIfNeeded(
        processID: pid_t,
        appElement: AXUIElement
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let until = manualAccessibilityUnsupportedUntil[processID], now < until { return }
        if let lastEnabledAt = manualAccessibilityLastEnabledAt[processID],
            now - lastEnabledAt < 1_000_000_000
        {
            return
        }

        guard let previousValue = copyBool(Self.manualAccessibilityAttribute, from: appElement) else {
            return
        }
        manualAccessibilityPreviousValue[processID] = previousValue
        let result = AXUIElementSetAttributeValue(
            appElement,
            Self.manualAccessibilityAttribute,
            kCFBooleanTrue
        )
        switch result {
        case .success:
            manualAccessibilityLastEnabledAt[processID] = now
        case .attributeUnsupported, .notImplemented:
            manualAccessibilityUnsupportedUntil[processID] = now + 60_000_000_000
        default:
            break
        }
    }

    private func appendUnique(
        _ element: AXUIElement,
        source: String,
        to candidates: inout [(element: AXUIElement, source: String)]
    ) {
        guard !candidates.contains(where: { CFEqual($0.element, element) }) else { return }
        candidates.append((element, source))
    }

    private func owningProcessID(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return processID
    }

    private func attributeNames(of element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let values = names as? [String]
        else {
            return []
        }
        return Set(values)
    }

    private func parameterizedAttributeNames(of element: AXUIElement) -> Set<String> {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
            let values = names as? [String]
        else {
            return []
        }
        return Set(values)
    }

    private func copyElement(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = copyOpaque(attribute, from: element),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyBool(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        (copyOpaque(attribute, from: element) as? NSNumber)?.boolValue
    }

    private func copyInteger(_ attribute: CFString, from element: AXUIElement) -> Int? {
        (copyOpaque(attribute, from: element) as? NSNumber)?.intValue
    }

    private func copyString(_ attribute: CFString, from element: AXUIElement) -> String? {
        let value = copyOpaque(attribute, from: element)
        if let text = value as? String {
            return text
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private func copyRange(_ attribute: CFString, from element: AXUIElement) -> NSRange? {
        guard let value = copyOpaque(attribute, from: element),
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetType(value as! AXValue) == .cfRange
        else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
            range.location != kCFNotFound,
            range.location >= 0,
            range.length >= 0
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func copyStringForRange(_ range: NSRange, from element: AXUIElement) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        guard let value = copyOpaqueParameterized(
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter: rangeValue,
            from: element
        ) else {
            return nil
        }
        if let text = value as? String {
            return text
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private func markerRange(
        from start: CFTypeRef,
        to end: CFTypeRef,
        on element: AXUIElement
    ) -> CFTypeRef? {
        copyOpaqueParameterized(
            Self.rangeForMarkersAttribute,
            parameter: [start, end] as CFArray,
            from: element
        )
    }

    private func stringForMarkerRange(_ range: CFTypeRef, on element: AXUIElement) -> String? {
        let value = copyOpaqueParameterized(
            Self.stringForMarkerRangeAttribute,
            parameter: range,
            from: element
        )
        if let text = value as? String {
            return text
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private func copyOpaque(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func copyOpaqueParameterized(
        _ attribute: CFString,
        parameter: CFTypeRef,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

#if DEBUG
    extension AutoLearnAXTextReader {
        static func selfCheck() {
            let textField = kAXTextFieldRole as String
            let secure = kAXSecureTextFieldSubrole as String
            let password = AutoLearnAXFieldDescription(role: textField, subrole: secure, characterCount: 8)
            assert(exclusion(for: password, secureInputEnabled: false) == .secureField, "native and web password fields")
            let secureRole = AutoLearnAXFieldDescription(role: secure, subrole: nil, characterCount: nil)
            assert(exclusion(for: secureRole, secureInputEnabled: false) == .secureField)
            let plain = AutoLearnAXFieldDescription(role: textField, subrole: nil, characterCount: 120)
            assert(exclusion(for: plain, secureInputEnabled: false) == nil, "an ordinary field is read")
            let area = AutoLearnAXFieldDescription(role: kAXTextAreaRole as String, subrole: nil, characterCount: nil)
            assert(exclusion(for: area, secureInputEnabled: false) == nil, "no character count: read, capped later")
            assert(exclusion(for: plain, secureInputEnabled: true) == .secureInput, "secure input refuses every field")
            let limit = AutoLearnLimits.maximumFieldUTF16Length
            let atLimit = AutoLearnAXFieldDescription(role: textField, subrole: nil, characterCount: limit)
            assert(exclusion(for: atLimit, secureInputEnabled: false) == nil)
            let huge = AutoLearnAXFieldDescription(role: kAXTextAreaRole as String, subrole: nil, characterCount: limit + 1)
            assert(exclusion(for: huge, secureInputEnabled: false) == .fieldTooLong)

            // Only a count per reason is kept.
            let suite = "yap.selfcheck.autolearn.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            AutoLearnUnobservableCounts.record(.secureField, defaults: defaults)
            AutoLearnUnobservableCounts.record(.secureField, defaults: defaults)
            AutoLearnUnobservableCounts.record(.fieldTooLong, defaults: defaults)
            assert(AutoLearnUnobservableCounts.all(defaults: defaults) == [.secureField: 2, .fieldTooLong: 1])
            assert(defaults.persistentDomain(forName: suite).map { Array($0.keys) } == [AutoLearnUnobservableCounts.defaultsKey])
        }
    }
#endif
