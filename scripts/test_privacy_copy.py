#!/usr/bin/env python3
"""Source contracts, not runtime privacy verification. Usage: python3 scripts/test_privacy_copy.py [checkout]."""
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
if __name__ == "__main__" and len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    ROOT = Path(sys.argv.pop(1))


class PrivacyCopyTests(unittest.TestCase):
    def setUp(self):
        self.site = (ROOT / 'site/index.html').read_text()
        self.trust = (ROOT / 'VoiceInk/Features/Onboarding/Views/OnboardingTrustScreen.swift').read_text()
        self.agent = (ROOT / 'VoiceInk/Features/Settings/Views/AgentAccessSettingsSection.swift').read_text()
        catalog_path = ROOT / 'VoiceInk/PrivacyCopy.xcstrings'
        self.catalog = json.loads(catalog_path.read_text())['strings'] if catalog_path.exists() else {}

    def test_local_claim_scopes_both_processing_stages(self):
        self.assertIn('both transcription and enhancement use local models', self.site)
        self.assertIn('Choose local transcription and local enhancement for on-device processing.', self.trust)
        self.assertNotIn('Everything stays on this Mac.', self.site)

    def test_no_blanket_usage_or_history_exclusivity_claim(self):
        for source in (self.site, self.trust):
            self.assertNotIn('Yap collects no usage data.', source)
        self.assertIn('Yap saves history on this Mac. Cloud processing sends audio or text', self.trust)

    def test_enabled_context_is_disclosed(self):
        for source in (self.site, self.trust):
            self.assertIn('audio, text and enabled context', source)

    def test_cloud_billing_is_disclosed_without_unsupported_retention_promise(self):
        self.assertIn('records the model and cost for billing', self.site)
        self.assertNotIn('for billing, not the content', self.site)
        self.assertIn('see the privacy policy for data handling', self.site)

    def test_agent_boundary_is_disclosed(self):
        self.assertIn('Connected agents may send the data they read to their own services.', self.site)
        self.assertIn('Connected agents may send it to their own services.', self.agent)
        self.assertIn('Their own privacy policies apply.', self.trust)

    def test_new_app_copy_has_all_supported_translations(self):
        keys = [
            'Yap saves history on this Mac. Cloud processing sends audio or text to your chosen services.',
            'Local models process audio or text on this Mac. Choose local transcription and local enhancement for on-device processing.',
            'With your own API key, cloud models receive the audio, text and enabled context needed for the request.',
            "Yap Cloud sends requests through Yap's server to model providers and records the model and cost for billing.",
            "Optional cloud sync stores modes, prompts, dictionary, shortcuts and custom models on Yap's server, without your API keys.",
            'If you enable Agent Access (MCP), connected agents can read allowed history and dictionary data. Their own privacy policies apply.',
            'The helper reads data locally. Connected agents may send it to their own services.',
        ]
        for key in keys:
            for language in ('de', 'fr', 'zh-Hans', 'zh-Hant'):
                with self.subTest(key=key, language=language):
                    self.assertTrue(self.catalog.get(key, {}).get('localizations', {}).get(language, {}).get('stringUnit', {}).get('value'))

    def test_upstream_credit_and_license_remain(self):
        self.assertIn('Yap is a fork of', self.site)
        self.assertIn('https://github.com/Beingpax/VoiceInk', self.site)
        self.assertIn('GPL-3.0', self.site)
        self.assertIn('GNU GENERAL PUBLIC LICENSE', (ROOT / 'LICENSE').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
