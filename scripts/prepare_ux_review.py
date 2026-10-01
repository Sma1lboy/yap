#!/usr/bin/env python3
"""Instrument only the disposable Debug snapshot build, equally before/after.

The production sources at the recorded SHA remain the source of every rendered view.
The recorded fixture.patch makes initial state/fixture changes explicit: expanded
privacy, fake permission statuses, stopped download error, and pending preset.
The snapshot guard keeps its existing ONLY filter before limiting the UX review pages.
No permissions, recording, credentials or network requests are performed by this script.
"""
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()

def edit(path, changes):
    p = root / path
    source = p.read_text()
    for before, after in changes:
        count = source.count(before)
        if count != 1:
            raise RuntimeError(f'{path}: expected one fixture marker, found {count}: {before[:100]}')
        source = source.replace(before, after)
    p.write_text(source)

edit('VoiceInk/Features/Onboarding/Views/OnboardingTrustScreen.swift', [
    ('@State private var showsPrivacyDetails = false', '@State private var showsPrivacyDetails = true  // UX review fixture: expanded privacy details'),
])
edit('VoiceInk/Features/Onboarding/Views/OnboardingModelScreen.swift', [
    ('@State private var recommendedAPIKey = ""', '@State private var recommendedAPIKey = Self.uxReviewApplyingPreset ? "sample-fixture-key" : ""'),
    ('@State private var isApplyingRecommended = false', '@State private var isApplyingRecommended = Self.uxReviewApplyingPreset\n    static var uxReviewApplyingPreset = false  // Disposable Debug fixture only'),
])
p = root / 'VoiceInk/App/Debug/UISnapshots.swift'
source = p.read_text()
old_start = source.index('        private static var onboardingPermissions: some View {')
old_end = source.index('        private static func onboardingModel(', old_start)
old_permissions = source[old_start:old_end]
new_permissions = '''        private static func onboardingPermissions(
            isComplete: Bool = false, requestedScreen: Bool = false, allMissing: Bool = false
        ) -> some View {
            // Populate every status: the production controller never needs to diagnose a real permission.
            let coordinator = OnboardingCoordinator()
            coordinator.permissionStatuses = [
                .microphone: allMissing ? .needsAccess : .granted,
                .accessibility: isComplete ? .granted : .needsAccess,
                .screenRecording: .needsAccess,
            ]
            coordinator.hasRequestedScreenRecording = requestedScreen
            precondition(coordinator.requiredPermissionsGranted == isComplete)
            precondition(!OnboardingPermissionKind.screenRecording.isRequired)
            precondition(coordinator.permissions.isLocked(.accessibility) == allMissing)
            precondition(coordinator.permissions.isLocked(.screenRecording) == !isComplete)
            print("UX permission fixture checks passed: complete=\\(isComplete), requested=\\(requestedScreen), allMissing=\\(allMissing)")
            return OnboardingPermissionsScreen(
                contentMaxWidth: 620, isComplete: isComplete,
                activePermission: isComplete ? .screenRecording : (allMissing ? .microphone : .accessibility),
                hasRequestedScreenRecording: requestedScreen,
                stepNumber: { coordinator.permissions.stepNumber(for: $0) },
                status: { coordinator.permissions.status(for: $0) },
                isLocked: { coordinator.permissions.isLocked($0) },
                actionTitle: { coordinator.permissions.actionTitle(for: $0) },
                onSelect: { _ in }, onAction: { _ in }, onQuit: {}, onRecheck: {}, onContinue: {},
                isRestoredFromCloud: false, onRestoreFromCloud: {})
        }

'''
edit('VoiceInk/App/Debug/UISnapshots.swift', [
    ('guard main || suffix.isEmpty, only.isEmpty || only.contains(where: name.hasPrefix) else { return }', '''guard main || suffix.isEmpty, only.isEmpty || only.contains(where: name.hasPrefix) else { return }
                guard name.hasPrefix("onboarding-1-") || name.hasPrefix("onboarding-3-")
                    || name.hasPrefix("onboarding-7-") || name.hasPrefix("settings-agent") else { return }'''),
    (old_permissions, new_permissions),
    ('shot("onboarding-1-permissions", size: onboardingSize, main: true) { onboardingPermissions }', '''shot("onboarding-1-permissions", size: onboardingSize, main: true) { onboardingPermissions() }
            shot("onboarding-1-permissions-optional-pending", size: onboardingSize, main: true) {
                onboardingPermissions(isComplete: true, requestedScreen: true)
            }
            shot("onboarding-1-permissions-earlier-required", size: onboardingSize, main: true) {
                onboardingPermissions(allMissing: true)
            }
            YapCloud.shared.applySnapshotState(.funded)
            OnboardingModelScreen.uxReviewApplyingPreset = true
            shot("onboarding-3-applying-yapcloud", size: onboardingSize, main: true) { onboardingModel(.yapCloud) }
            shot("onboarding-3-applying-openrouter", size: onboardingSize, main: true) { onboardingModel(.recommended) }
            OnboardingModelScreen.uxReviewApplyingPreset = false
            YapCloud.shared.applySnapshotState(.signedOut)
            shot("onboarding-3-model-local-failed", size: onboardingSize, main: true) {
                onboardingModel(.local,
                    downloading: .init(received: 240_000_000, total: 574_041_195, bytesPerSecond: 4_500_000),
                    downloadError: "Sample failure: not enough disk space.")
            }'''),
    ('_ kind: OnboardingTranscriptionSetupKind, downloading: ModelFileDownloader.Progress? = nil', '_ kind: OnboardingTranscriptionSetupKind, downloading: ModelFileDownloader.Progress? = nil, downloadError: String? = nil'),
    ('isLocalDownloaded: false, isLocalDownloading: downloading != nil,', 'isLocalDownloaded: false, isLocalDownloading: downloading != nil && downloadError == nil,'),
    ('localDownloadError: nil, isSetupReady: false, isShowingSkipWarning: .constant(false),', 'localDownloadError: downloadError, isSetupReady: OnboardingModelScreen.uxReviewApplyingPreset, isShowingSkipWarning: .constant(false),'),
])
print('Prepared explicit, isolated UX fixtures; production view/layout code is unchanged')
