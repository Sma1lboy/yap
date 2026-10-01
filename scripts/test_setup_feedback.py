#!/usr/bin/env python3
"""Setup source contracts. No keys, inference, model downloads or native UI calls are made."""
import json
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parents[1]
if __name__ == "__main__" and len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    ROOT = Path(sys.argv.pop(1))

class SetupFeedbackTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / 'VoiceInk/Features/Onboarding'
        self.screen = (base/'Views/OnboardingModelScreen.swift').read_text()
        self.card = (base/'Components/OnboardingTranscriptionSetupCard.swift').read_text()
        self.download = (base/'Components/TranscriptionModelDownloadCard.swift').read_text()

    def test_duplicate_preset_submit_is_guarded(self):
        action = self.screen.split('private func continueTapped()')[1].split('var body:')[0]
        self.assertIn('guard !isApplyingRecommended else { return }', action)
        self.assertIn('let requestedSetup = setupKind', action)
        self.assertIn('let error = requestedSetup == .yapCloud', action)

    def test_pending_preset_disables_conflicting_navigation_and_has_feedback(self):
        self.assertIn('.disabled(isApplyingRecommended)\n        .alert',self.screen)
        self.assertIn('guard !isApplyingRecommended else { return false }', self.screen)
        self.assertIn('Applying setup…', self.screen)
        self.assertIn('Applying your transcription and enhancement settings…', self.card)

    def test_switching_setup_clears_stale_error(self):
        self.assertIn('.onChange(of: setupKind) { _, _ in recommendedError = nil }',self.screen)

    def test_verification_is_scoped_to_attempt_provider_key_and_setup(self):
        response = self.card.split('let result = await selectedProvider.verifyAPIKey(key)')[1]
        for condition in ('verificationAttemptID == attemptID','setupKind == .cloud','self.selectedProvider?.providerKey == providerKey','trimmedAPIKey == key'):
            self.assertIn(condition,response)
        self.assertLess(response.index('verificationAttemptID == attemptID'), response.index('isVerifying = false'))
        self.assertLess(response.index('verificationAttemptID == attemptID'), response.index('saveAPIKey(key'))

    def test_edit_leave_and_provider_change_invalidate_pending_verification(self):
        self.assertIn('.onDisappear { invalidateVerificationAttempt() }', self.card)
        for marker in ('.onChange(of: apiKey)', '.onChange(of: setupKind)', 'private func handleProviderChange()'):
            self.assertIn('invalidateVerificationAttempt()',self.card.split(marker)[1].split('\n    }')[0])

    def test_saved_key_does_not_claim_current_connection(self):
        summary = self.card.split('private var verifiedProviderSummary')[1].split('private var statusLine')[0]
        self.assertIn('API key saved.',summary)
        self.assertNotIn('Connection verified.',summary)

    def test_missing_model_provides_recovery(self):
        self.assertIn('Choose a cloud option, or set up a local model later in Models.', self.card)

    def test_download_failure_is_not_hidden_by_stale_progress(self):
        body = self.download.split('var body:')[1].split('private var header:')[0]
        self.assertLess(body.index('if let errorMessage'),body.index('else if let status'))
        self.assertIn('!isDownloaded && !isDownloading',body)
        self.assertNotIn('Check your connection and try again.',body)
        button = self.download.split('private var downloadButtonTitle')[1]
        self.assertLess(button.index('if errorMessage != nil'),button.index('if status != nil'))

    def test_all_new_messages_have_translations(self):
        path=ROOT/'VoiceInk/SetupCopy.xcstrings'
        self.assertTrue(path.exists())
        for key,entry in json.loads(path.read_text())['strings'].items():
            for language in ('de','fr','zh-Hans','zh-Hant'):
                with self.subTest(key=key,language=language):
                    self.assertTrue(entry['localizations'][language]['stringUnit']['value'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
