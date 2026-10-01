#!/usr/bin/env python3
"""Permission source contracts. macOS permission APIs are not exercised."""
import json
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[1]
if __name__ == "__main__" and len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    ROOT = Path(sys.argv.pop(1))

class PermissionCopyTests(unittest.TestCase):
    def read(self, part):
        return (ROOT / 'VoiceInk/Features/Onboarding' / part).read_text()

    def test_only_microphone_and_accessibility_are_required(self):
        source = self.read('State/OnboardingPermissionModels.swift')
        self.assertIn('[.microphone, .accessibility]', source)
        self.assertIn('Screen Recording (optional)', source)
        self.assertIn('Screen Recording is optional for dictation.', source)

    def test_screen_permission_explains_both_features(self):
        self.assertIn('Used for screen context and meeting audio from other apps.', self.read('State/OnboardingPermissionModels.swift'))

    def test_restart_recovery_does_not_depend_on_active_row(self):
        source = self.read('Components/PermissionStepRow.swift')
        self.assertIn('if !isLocked && showsRestartHint {', source)
        self.assertNotIn('if isActive && !isLocked && showsRestartHint', source)
        self.assertIn('You can also continue without Screen Recording.', source)

    def test_repeated_screen_request_opens_settings(self):
        source = self.read('State/OnboardingPermissionController.swift')
        action = source.split('private func requestScreenRecording() {')[1].split('private func advanceFrom')[0]
        self.assertIn('if coordinator.hasRequestedScreenRecording {', action)
        self.assertLess(action.index('openPrivacySettings(.screenRecording)'), action.index('requestScreenCapturePermissionRegistration'))
        self.assertIn('return coordinator.hasRequestedScreenRecording ? String(localized: "Open Settings")', source)

    def test_locked_status_explains_next_action(self):
        source = self.read('Components/PermissionStepRow.swift')
        self.assertIn('Text("Finish earlier permissions first", tableName: "PermissionCopy")', source)
        badge = source.split('private var statusBadge')[1].split('private var statusTone')[0]
        self.assertIn('String(localized: "Waiting", table: "PermissionCopy")', badge)
        self.assertNotIn('Finish earlier permissions first', badge)

    def test_localized_catalog_and_wiring(self):
        path = ROOT / 'VoiceInk/PermissionCopy.xcstrings'
        self.assertTrue(path.exists())
        for key, entry in json.loads(path.read_text())['strings'].items():
            for language in ('de','fr','zh-Hans','zh-Hant'):
                with self.subTest(key=key, language=language):
                    self.assertTrue(entry['localizations'][language]['stringUnit']['value'])
        for part in ('State/OnboardingPermissionModels.swift','Components/PermissionStepRow.swift'):
            self.assertIn('"PermissionCopy"',self.read(part))

if __name__ == '__main__':
    unittest.main(verbosity=2)
