import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/download_manager.dart';

class DownloadState {
  final bool isDownloading;
  final double progress;
  final String statusText;
  final String? error;
  final bool isComplete;
  final bool isDelta; // true when using delta patch
  final bool installBlocked; // installer shown but app still not installed on resume
  final bool installPending; // download ready, installer not opened yet (backgrounded)
  final bool installedNow; // install session succeeded — UI should flip to "Open"
  final bool canResume; // interrupted download on disk — offer to continue it

  DownloadState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.statusText = '',
    this.error,
    this.isComplete = false,
    this.isDelta = false,
    this.installBlocked = false,
    this.installPending = false,
    this.installedNow = false,
    this.canResume = false,
  });
}

class DownloadNotifier extends StateNotifier<DownloadState> {
  /// [manager] is a test seam; the app uses the shared [DownloadManager].
  DownloadNotifier({DownloadManager? manager})
      : _manager = manager ?? DownloadManager(),
        super(DownloadState()) {
    // Install-outcome events from the native PackageInstaller session.
    _installEvents = _manager.installEvents.stream.listen((e) {
      if (e == 'installed') {
        state = DownloadState(statusText: 'Installed', installedNow: true);
      } else if (e == 'needs_user') {
        state = DownloadState(
          installPending: true,
          statusText: 'Ready to install',
        );
      }
    });
  }

  final DownloadManager _manager;
  late final StreamSubscription<String> _installEvents;

  @override
  void dispose() {
    _installEvents.cancel();
    super.dispose();
  }

  /// Full APK download (original flow).
  Future<void> startDownload({
    required String url,
    required String? sha256,
    required String versionName,
  }) async {
    state = DownloadState(
      isDownloading: true,
      progress: 0.0,
      statusText: 'Starting download...',
    );

    await _manager.downloadAndInstall(
      url: url,
      expectedSha256: sha256,
      versionName: versionName,
      onProgress: (progress, status) {
        state = DownloadState(
          isDownloading: true,
          progress: progress,
          statusText: status,
        );
      },
      onComplete: (filePath) {
        state = DownloadState(
          isDownloading: false,
          progress: 1.0,
          statusText: 'Installing...',
          isComplete: true,
        );
      },
      onError: (error) {
        state = DownloadState(
          isDownloading: false,
          progress: 0.0,
          error: error,
        );
      },
      onPaused: (progress) {
        state = DownloadState(
          canResume: true,
          progress: progress.clamp(0.0, 1.0),
          statusText: 'Paused at ${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
        );
      },
    );
  }

  /// An interrupted download exists (store was closed mid-download).
  /// The UI offers "Resume" carrying on from [progress].
  void markResumable(double progress) {
    state = DownloadState(
      canResume: true,
      progress: progress.clamp(0.0, 1.0),
      statusText: 'Paused at ${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
    );
  }

  /// Continues the interrupted download; falls back to a fresh one when
  /// there is nothing left to resume.
  Future<void> resumeDownload({
    required String url,
    required String? sha256,
    required String versionName,
  }) async {
    state = DownloadState(
      isDownloading: true,
      progress: state.progress,
      statusText: 'Resuming...',
    );

    await _manager.resumeDownload(
      url: url,
      expectedSha256: sha256,
      versionName: versionName,
      onProgress: (progress, status) {
        state = DownloadState(
          isDownloading: true,
          progress: progress,
          statusText: status,
        );
      },
      onComplete: (filePath) {
        state = DownloadState(
          isDownloading: false,
          progress: 1.0,
          statusText: 'Installing...',
          isComplete: true,
        );
      },
      onError: (error) {
        state = DownloadState(
          isDownloading: false,
          progress: 0.0,
          error: error,
        );
      },
      onPaused: (progress) {
        state = DownloadState(
          canResume: true,
          progress: progress.clamp(0.0, 1.0),
          statusText: 'Paused at ${(progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
        );
      },
    );
  }

  /// User tapped Pause: keep the partial bytes, show the paused card.
  void pauseDownload() {
    _manager.pauseDownload();
  }

  /// Delta patch download + apply (smaller, faster).
  Future<void> startDeltaUpdate({
    required String patchUrl,
    required String patchSha256,
    required String fullApkSha256,
    required String packageName,
    required String versionName,
    required String fullDownloadUrl,
    required int fullFileSizeBytes,
  }) async {
    state = DownloadState(
      isDownloading: true,
      progress: 0.0,
      statusText: 'Preparing delta update...',
      isDelta: true,
    );

    await _manager.downloadAndApplyPatch(
      patchUrl: patchUrl,
      patchSha256: patchSha256,
      fullApkSha256: fullApkSha256,
      packageName: packageName,
      versionName: versionName,
      fullDownloadUrl: fullDownloadUrl,
      fullFileSizeBytes: fullFileSizeBytes,
      onProgress: (progress, status) {
        state = DownloadState(
          isDownloading: true,
          progress: progress,
          statusText: status,
          isDelta: true,
        );
      },
      onComplete: (filePath) {
        state = DownloadState(
          isDownloading: false,
          progress: 1.0,
          statusText: 'Installing...',
          isComplete: true,
          isDelta: true,
        );
      },
      onError: (error) {
        state = DownloadState(
          isDownloading: false,
          progress: 0.0,
          error: error,
        );
      },
    );
  }

  void cancelDownload() {
    _manager.cancelDownload();
    state = DownloadState();
  }

  void clearError() {
    state = DownloadState();
  }

  /// Called by the UI when the app resumes from the system installer and the
  /// target app is confirmed installed at the expected version.
  void markInstallVerified() {
    state = DownloadState(statusText: 'Installed');
  }

  /// Called when the app resumes from the installer but the app is still not
  /// installed — the user cancelled, or Android refused the update (typical:
  /// signature conflict with an existing installation). The UI shows a clear
  /// recovery hint instead of freezing on "Installing…".
  /// Download finished (possibly while backgrounded) but the app is not
  /// installed yet — nothing is wrong, the user just needs to open the
  /// installer now that the store is foregrounded again.
  void markInstallPending() {
    state = DownloadState(
      installPending: true,
      statusText: 'Ready to install',
    );
  }

  /// Opens the already-downloaded APK in the system installer. The manager
  /// re-verifies the file first (and against [currentSha256], the release on
  /// screen, when given); a file that fails is deleted, never installed.
  Future<void> openStoredInstaller({String? currentSha256}) async {
    final result = await _manager.retryInstallFromStored(currentSha256: currentSha256);
    final code = '${result['message'] ?? ''}';
    if (result['success'] == true) {
      state = DownloadState(statusText: 'Installed', installedNow: true);
    } else if (code == 'pending_user_action_background') {
      // The dialog is waiting for the user.
      state = DownloadState(
        isDownloading: false,
        progress: 1.0,
        statusText: 'Installing...',
        isComplete: true,
      );
    } else {
      state = DownloadState(
        error: DownloadManager.describeInstallFailure(
          code,
          fallback: 'Could not open the installer. Start the download again.',
        ),
      );
    }
  }

  void markInstallBlocked() {
    state = DownloadState(
      installBlocked: true,
      statusText: 'Installation did not complete',
    );
  }
}

/// The download engine. Overridable so widget tests can inject one with a
/// fake HTTP client, staging directory and native channel.
final downloadManagerProvider = Provider<DownloadManager>((ref) => DownloadManager());

final downloadProvider = StateNotifierProvider<DownloadNotifier, DownloadState>((ref) {
  return DownloadNotifier(manager: ref.read(downloadManagerProvider));
});

/// False when this Store build has no pinned signer certificate: every
/// install is refused natively, and the UI says so up front.
final installsAllowedProvider = FutureProvider<bool>((ref) {
  return ref.read(downloadManagerProvider).installsAllowed();
});
