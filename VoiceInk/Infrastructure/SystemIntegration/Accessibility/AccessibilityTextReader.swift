import ApplicationServices
import Carbon  // IsSecureEventInputEnabled
import Foundation

struct AccessibilityTextReading {
    let appElement: AXUIElement
    let targetElement: AXUIElement
    let fieldText: String
    let selection: NSRange?
    let source: String
    let focusSource: String
}

struct AccessibilityTextValue {
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
    let readings: [AccessibilityTextReading]
    /// Set when a focused element was refused before reading anything; `readings` is then empty.
    let exclusion: AutoLearnUnobservableReason?
}

/// Reads editable text through macOS Accessibility only. Web accessibility is
/// activated on demand; no keyboard event tap or Input Monitoring is involved.
final class AccessibilityTextReader {
    static let maximumFieldUTF16Length = 100_000
    private let messagingTimeout: Float
    private let fieldMessagingTimeout: Float?
    private let readBudget: TimeInterval?
    private var readDeadline: TimeInterval?

    private var canRead: Bool {
        readDeadline.map { ProcessInfo.processInfo.systemUptime < $0 } ?? true
    }

    init(messagingTimeout: Float = 0.10, fieldMessagingTimeout: Float? = nil, readBudget: TimeInterval? = nil) {
        self.messagingTimeout = messagingTimeout
        self.fieldMessagingTimeout = fieldMessagingTimeout
        self.readBudget = readBudget
    }

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

    private var webAccessibilityProcesses = Set<pid_t>()

    /// The focused editable field's text; empty for a password field or while secure input is on (focusedText).
    func focusedReadings(processID: pid_t, includeSystemFocus: Bool = true) -> [AccessibilityTextReading] {
        focusedText(processID: processID, includeSystemFocus: includeSystemFocus).readings
    }

    /// The focused editable field's text. Every focused candidate is described before any value is read: while secure
    /// input is on, or if one of them is a password field, nothing is read from any of them; a field that's too long
    /// is skipped. With a read budget, nothing is returned once it runs out.
    func focusedText(processID: pid_t, includeSystemFocus: Bool = true) -> AutoLearnAXFocusedText {
        if IsSecureEventInputEnabled() {
            return AutoLearnAXFocusedText(readings: [], exclusion: .secureInput)
        }
        readDeadline = readBudget.map { ProcessInfo.processInfo.systemUptime + $0 }
        defer { readDeadline = nil }
        let appElement = focusedApplication(processID: processID)
        let candidates = focusedCandidates(
            processID: processID, appElement: appElement, includeSystemFocus: includeSystemFocus)
        if candidates.contains(where: { $0.exclusion == .secureField }) {
            restoreWebAccessibility(processID: processID, appElement: appElement)
            return AutoLearnAXFocusedText(readings: [], exclusion: .secureField)
        }

        var readings: [AccessibilityTextReading] = []
        var skippedTooLong = false
        for candidate in candidates {
            guard isEditable(candidate.element) else { continue }
            guard candidate.exclusion == nil else {
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
        guard canRead else { return AutoLearnAXFocusedText(readings: [], exclusion: nil) }
        return AutoLearnAXFocusedText(
            readings: readings, exclusion: readings.isEmpty && skippedTooLong ? .fieldTooLong : nil)
    }

    /// Only the selected text of the focused editable field: what a paste is about to replace (Undo Last Paste). The
    /// same fields are refused as by focusedText, but the rest of the field isn't read, so this read, which ⌘V waits
    /// for, doesn't grow with the field. Empty when nothing is selected or the field is refused. The caller restores
    /// web accessibility.
    func focusedSelection(processID: pid_t) -> String {
        if IsSecureEventInputEnabled() { return "" }
        let candidates = focusedCandidates(
            processID: processID, appElement: focusedApplication(processID: processID), includeSystemFocus: true)
        guard !candidates.contains(where: { $0.exclusion == .secureField }) else { return "" }
        for candidate in candidates where candidate.exclusion == nil && isEditable(candidate.element) {
            if let selected = selectedText(of: candidate.element) { return selected }
        }
        return ""
    }

    private func focusedApplication(processID: pid_t) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(
            appElement,
            messagingTimeout
        )
        enableWebAccessibilityIfNeeded(processID: processID, appElement: appElement)
        return appElement
    }

    /// The application's and the system's focused element, each described (not read) and judged first.
    private func focusedCandidates(
        processID: pid_t, appElement: AXUIElement, includeSystemFocus: Bool
    ) -> [(element: AXUIElement, source: String, exclusion: AutoLearnUnobservableReason?)] {
        var candidates: [(element: AXUIElement, source: String)] = []
        if let appFocused = AccessibilityFocusReader.focusedElement(in: appElement).element {
            appendUnique(appFocused, source: "application-focus", to: &candidates)
        }

        if includeSystemFocus {
            let systemWide = AXUIElementCreateSystemWide()
            if let systemFocused = AccessibilityFocusReader.focusedElement(in: systemWide).element,
                AccessibilityFocusReader.processID(of: systemFocused) == processID
            {
                appendUnique(systemFocused, source: "system-focus", to: &candidates)
            }
        }

        if let fieldMessagingTimeout {
            for candidate in candidates { AXUIElementSetMessagingTimeout(candidate.element, fieldMessagingTimeout) }
        }
        return candidates.map {
            ($0.element, $0.source, Self.exclusion(for: describe($0.element), secureInputEnabled: false))
        }
    }

    /// The selection's own text: the native selected range, or the selected text-marker range in web fields.
    private func selectedText(of element: AXUIElement) -> String? {
        if let range = copyRange(kAXSelectedTextRangeAttribute as CFString, from: element) {
            guard range.length > 0 else { return nil }
            if let text = copyStringForRange(range, from: element)
                ?? copyString(kAXSelectedTextAttribute as CFString, from: element), !text.isEmpty
            {
                return text
            }
        }
        guard let markers = copyOpaque(Self.selectedMarkerRangeAttribute, from: element),
            let text = stringForMarkerRange(markers, on: element), !text.isEmpty
        else { return nil }
        return text
    }

    /// Why a field must not be read, from what it says about itself; nil when it may be. Secure input (system-wide,
    /// on while any password field has focus) refuses every field.
    static func exclusion(
        for field: AutoLearnAXFieldDescription, secureInputEnabled: Bool
    ) -> AutoLearnUnobservableReason? {
        if secureInputEnabled { return .secureInput }
        let secure = kAXSecureTextFieldSubrole as String
        if field.role == secure || field.subrole == secure { return .secureField }
        if let count = field.characterCount, count > maximumFieldUTF16Length { return .fieldTooLong }
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
        guard webAccessibilityProcesses.remove(processID) != nil else { return }
        AccessibilityWebAccess.shared.release(processID: processID) { previous in
            _ = AXUIElementSetAttributeValue(appElement, Self.manualAccessibilityAttribute,
                previous ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        guard copyString(kAXSubroleAttribute as CFString, from: element) != kAXSecureTextFieldSubrole,
            copyBool("AXProtectedContent" as CFString, from: element) != true else { return false }
        return AccessibilityFocusReader.editableState(of: element) == true
    }

    func textValue(from element: AXUIElement) -> AccessibilityTextValue? {
        let attributes = attributeNames(of: element)
        let parameterizedAttributes = parameterizedAttributeNames(of: element)

        if parameterizedAttributes.contains(kAXStringForRangeParameterizedAttribute as String),
            attributes.contains(kAXNumberOfCharactersAttribute as String),
            let documentLength = copyInteger(kAXNumberOfCharactersAttribute as CFString, from: element),
            documentLength >= 0,
            documentLength <= Self.maximumFieldUTF16Length,
            let text = copyStringForRange(
                NSRange(location: 0, length: documentLength),
                from: element
            ),
            documentLength == 0 || !text.isEmpty
        {
            return AccessibilityTextValue(text: text, source: "string-for-range")
        }

        guard let value = copyString(kAXValueAttribute as CFString, from: element),
            value.utf16.count <= Self.maximumFieldUTF16Length
        else {
            guard let markerSnapshot = markerSnapshot(from: element) else { return nil }
            return AccessibilityTextValue(text: markerSnapshot.text, source: "text-markers")
        }
        return AccessibilityTextValue(text: value, source: "value")
    }

    private func makeReadings(
        from element: AXUIElement,
        appElement: AXUIElement,
        focusSource: String
    ) -> [AccessibilityTextReading] {
        var result: [AccessibilityTextReading] = []

        if let textValue = textValue(from: element) {
            let reportedSelection = copyRange(
                kAXSelectedTextRangeAttribute as CFString,
                from: element
            )
            let selection = reportedSelection.flatMap {
                isValid($0, inUTF16Length: textValue.text.utf16.count) ? $0 : nil
            }
            result.append(
                AccessibilityTextReading(
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
    ) -> AccessibilityTextReading? {
        guard let snapshot = markerSnapshot(from: element) else { return nil }
        return AccessibilityTextReading(
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
        guard fieldText.utf16.count <= Self.maximumFieldUTF16Length else {
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

    private func enableWebAccessibilityIfNeeded(processID: pid_t, appElement: AXUIElement) {
        guard !webAccessibilityProcesses.contains(processID) else { return }
        let acquired = AccessibilityWebAccess.shared.acquire(processID: processID) {
            var value: CFTypeRef?
            let readError = AXUIElementCopyAttributeValue(appElement, Self.manualAccessibilityAttribute, &value)
            guard readError == .success else { return .failed(readError) }
            guard let previous = (value as? NSNumber)?.boolValue else { return .failed(.failure) }
            let writeError = AXUIElementSetAttributeValue(appElement, Self.manualAccessibilityAttribute, kCFBooleanTrue)
            return writeError == .success ? .enabled(previous: previous) : .failed(writeError)
        }
        if acquired { webAccessibilityProcesses.insert(processID) }
    }

    private func appendUnique(
        _ element: AXUIElement,
        source: String,
        to candidates: inout [(element: AXUIElement, source: String)]
    ) {
        guard !candidates.contains(where: { CFEqual($0.element, element) }) else { return }
        candidates.append((element, source))
    }

    private func attributeNames(of element: AXUIElement) -> Set<String> {
        guard canRead else { return [] }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let values = names as? [String]
        else {
            return []
        }
        return Set(values)
    }

    private func parameterizedAttributeNames(of element: AXUIElement) -> Set<String> {
        guard canRead else { return [] }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success,
            let values = names as? [String]
        else {
            return []
        }
        return Set(values)
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
        guard canRead else { return nil }
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
        guard canRead else { return nil }
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
    extension AccessibilityTextReader {
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
            let limit = maximumFieldUTF16Length
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

/// Browser accessibility stays enabled until every reader has finished using it.
final class AccessibilityWebAccess: @unchecked Sendable {
    enum EnableResult {
        case enabled(previous: Bool)
        case failed(AXError)
    }

    static let shared = AccessibilityWebAccess()
    private let lock = NSLock()
    private var processes: [pid_t: (readers: Int, previous: Bool)] = [:]
    private var retryAfter: [pid_t: TimeInterval] = [:]

    func acquire(processID: pid_t, enable: () -> EnableResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if var state = processes[processID] {
            state.readers += 1
            processes[processID] = state
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        retryAfter = retryAfter.filter { $0.value > now }
        guard retryAfter[processID] == nil else { return false }
        switch enable() {
        case .enabled(let previous):
            processes[processID] = (readers: 1, previous: previous)
            return true
        case .failed(let error):
            let delay: TimeInterval = error == .attributeUnsupported || error == .notImplemented ? 60 : 1
            retryAfter[processID] = now + delay
            return false
        }
    }

    func release(processID: pid_t, restore: (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = processes[processID] else { return }
        state.readers -= 1
        if state.readers == 0 {
            processes.removeValue(forKey: processID)
            restore(state.previous)
        } else {
            processes[processID] = state
        }
    }
}
