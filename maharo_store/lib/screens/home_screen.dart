import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/store_provider.dart';
import '../providers/download_provider.dart';
import '../providers/installed_provider.dart';
import '../core/package_service.dart';
import '../models/store_version.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  static const _bg = Color(0xFF0A0E14);
  static const _card = Color(0xFF12181F);
  static const _teal = Color(0xFF00BFA5);
  static const _dim = Color(0xFF6B7280);

  /// True after the user tapped "Remove old version" in the blocked banner —
  /// only then may the store auto-restart the install when the old app is
  /// gone (prevents re-download loops when the user simply cancelled).
  bool _uninstallRequested = false;

  /// True once the system uninstall dialog failed to remove the old app
  /// (OEM ROMs like MIUI/OneUI sometimes block it). Then the blocked banner
  /// grows a manual fallback: open Android's own App Info page for Maharo,
  /// uninstall from there, and the store continues automatically on return.
  bool _manualRemovalHint = false;

  /// Auto-open the installer at most ONCE per finished download (when the
  /// store resumes after the download completed while backgrounded). If the
  /// user cancels that dialog, the "Install" button stays available instead
  /// of nagging them again.
  bool _autoInstallTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Single-APK policy: on every launch drop any stale APK/patch files,
    // keeping only the one retained latest APK (delta base).
    ref.read(downloadManagerProvider).cleanOldApks();

    // Interrupted download (store closed mid-download)? Offer to resume it
    // from where it stopped instead of restarting from zero.
    Future<void>.delayed(const Duration(milliseconds: 1200), () async {
      if (!mounted) return;
      final dl = ref.read(downloadProvider);
      if (dl.isDownloading || dl.isComplete) return;
      final progress = await ref.read(downloadManagerProvider).findResumableProgress();
      if (!mounted || progress == null) return;
      final now = ref.read(downloadProvider);
      if (now.isDownloading || now.isComplete) return;
      ref.read(downloadProvider.notifier).markResumable(progress);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// When the app is resumed (e.g. user returns from the system installer),
  /// verify whether the install actually completed. Android silently refuses
  /// cross-signature updates ("package conflicts with an existing package") —
  /// detect that and show a recovery hint instead of a frozen banner.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(installedVersionProvider('app.maharo'));
      final dl = ref.read(downloadProvider);
      if (dl.isComplete) {
        _verifyInstallOutcome();
      } else if (dl.installBlocked && _uninstallRequested) {
        _recoverAfterUninstall();
      } else if (dl.installPending && !_autoInstallTried) {
        // Download finished while the store was backgrounded — Android
        // blocked the installer launch from background. Open it now that
        // the store is in the foreground again.
        _autoInstallTried = true;
        _openStoredInstaller();
      }
    }
  }

  /// Opens the stored APK; the manager re-verifies it first, also against
  /// the hash of the release currently on screen.
  void _openStoredInstaller() {
    final latest = ref.read(latestVersionProvider('app.maharo')).valueOrNull;
    ref.read(downloadProvider.notifier).openStoredInstaller(currentSha256: latest?.sha256);
  }

  /// Runs after the user answered the system uninstall dialog triggered from
  /// the blocked banner. When the old app is gone, the store automatically
  /// restarts the install of the new version — completing the migration.
  Future<void> _recoverAfterUninstall() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    final installed = await PackageService.getInstalledVersion('app.maharo');
    if (!mounted) return;
    if (installed != null) {
      // Still installed — the ROM refused/blocked the dialog. Surface the
      // manual fallback (App Info page) instead of failing silently.
      setState(() => _manualRemovalHint = true);
      return;
    }
    if (_manualRemovalHint) setState(() => _manualRemovalHint = false);
    _uninstallRequested = false;
    final latest = ref.read(latestVersionProvider('app.maharo')).valueOrNull;
    if (latest != null) {
      ref.read(downloadProvider.notifier).clearError();
      ref.read(downloadProvider.notifier).startDownload(
        url: latest.downloadUrl,
        sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
        versionName: latest.versionName,
      );
    }
  }

  Future<void> _verifyInstallOutcome() async {
    // Give the package manager a moment to settle after the installer closed.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    // Compare the package's lastUpdateTime against the baseline captured right
    // before the installer opened. Unchanged timestamp = nothing was installed
    // (user cancelled, or Android refused a cross-signature update). This works
    // even when the old install shares the same versionCode as the new build.
    final before = ref.read(downloadManagerProvider).installBaselineTime;
    final after = await PackageService.getLastUpdateTime('app.maharo');
    ref.invalidate(installedVersionProvider('app.maharo'));
    if (!mounted) return;
    if (after > before) {
      ref.read(downloadProvider.notifier).markInstallVerified();
    } else if (after == 0) {
      // Not installed at all: fresh install where the installer could not
      // open from the background (Android BAL restriction) or the user
      // cancelled it. Nothing is broken — offer to open it now.
      ref.read(downloadProvider.notifier).markInstallPending();
    } else {
      ref.read(downloadProvider.notifier).markInstallBlocked();
    }
  }

  void _refreshAll() {
    ref.invalidate(appInfoProvider('app.maharo'));
    ref.invalidate(latestVersionProvider('app.maharo'));
    ref.invalidate(versionsProvider('app.maharo'));
    ref.invalidate(installedVersionProvider('app.maharo'));
    ref.invalidate(installsAllowedProvider);
    ref.read(downloadProvider.notifier).clearError();
  }

  @override
  Widget build(BuildContext context) {
    // When the native install session succeeds (even silently, possibly
    // while another app was in front), re-check the installed package so
    // the action button flips to "Open" right away — no store restart.
    ref.listen(downloadProvider, (prev, next) {
      if (next.installedNow && prev?.installedNow != true) {
        ref.invalidate(installedVersionProvider('app.maharo'));
      }
    });

    final appAsync = ref.watch(appInfoProvider('app.maharo'));
    final latestAsync = ref.watch(latestVersionProvider('app.maharo'));
    final versionsAsync = ref.watch(versionsProvider('app.maharo'));
    final installedAsync = ref.watch(installedVersionProvider('app.maharo'));
    final dl = ref.watch(downloadProvider);
    final installsAllowed = ref.watch(installsAllowedProvider).valueOrNull ?? true;

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: appAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2, color: _teal)),
          error: (e, _) => _errorView(),
          data: (app) {
            final latest = latestAsync.valueOrNull;
            final installed = installedAsync.valueOrNull;
            final versions = versionsAsync.valueOrNull ?? [];
            final iconUrl = app?.iconUrl;

            // Determine app state
            final appState = _getAppState(installed, latest);

            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                const SizedBox(height: 20),

                // Top bar
                Row(
                  children: [
                    const Expanded(
                      child: Text('Maharo Store',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white)),
                    ),
                    _circleBtn(Icons.refresh_rounded, _refreshAll),
                  ],
                ),

                const SizedBox(height: 28),

                // App header
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: iconUrl != null && iconUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: iconUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, __) => _fallbackIcon(),
                                errorWidget: (_, __, ___) => _fallbackIcon(),
                              )
                            : _fallbackIcon(),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          Text(app?.name ?? 'Maharo',
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                          const SizedBox(height: 4),
                          const Text('Educational Platform',
                              style: TextStyle(fontSize: 14, color: _dim)),
                          if (latest != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Latest v${latest.versionName}  •  ${(latest.fileSizeBytes / 1024 / 1024).toStringAsFixed(0)} MB',
                              style: const TextStyle(fontSize: 13, color: _dim),
                            ),
                          ],
                          // Show installed version if present
                          if (installed != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  width: 6, height: 6,
                                  decoration: BoxDecoration(
                                    color: appState == _AppState.upToDate ? _teal : const Color(0xFFF59E0B),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  appState == _AppState.upToDate
                                      ? 'Installed v${installed.versionName} — Up to date'
                                      : 'Installed v${installed.versionName} — Update available',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: appState == _AppState.upToDate ? _teal : const Color(0xFFF59E0B),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                if (!installsAllowed) ...[
                  _installsDisabledBanner(),
                  const SizedBox(height: 12),
                ],

                // Action button
                if (latest != null) ...[
                  if (dl.error != null) ...[
                    _errorBanner(dl.error!, () => ref.read(downloadProvider.notifier).clearError()),
                    const SizedBox(height: 12),
                  ],
                  if (dl.installPending) ...[
                    _installPendingCard(
                      onOpen: _openStoredInstaller,
                      onDismiss: () => ref.read(downloadProvider.notifier).clearError(),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (dl.installBlocked) ...[
                    _installBlockedBanner(
                      onDismiss: () => ref.read(downloadProvider.notifier).clearError(),
                      onRemoveOld: () {
                        _uninstallRequested = true;
                        PackageService.requestUninstall('app.maharo');
                      },
                      showManualFallback: _manualRemovalHint,
                      onOpenSettings: () {
                        _uninstallRequested = true;
                        PackageService.openAppDetails('app.maharo');
                      },
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (dl.isDownloading)
                    _downloadProgress(dl)
                  else if (dl.canResume)
                    _downloadProgress(dl, resumable: true)
                  else if (dl.isComplete)
                    _completeBanner()
                  else if (dl.error == null && !dl.installBlocked)
                    _actionButton(appState, latest),
                ] else if (latestAsync.isLoading)
                  const SizedBox(height: 52, child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: _teal)))
                else if (latestAsync.hasError)
                  _retryCard(
                    'Could not load the latest version.',
                    () => ref.invalidate(latestVersionProvider('app.maharo')),
                  )
                else
                  Container(
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
                    child: const Text('No version available', style: TextStyle(color: _dim, fontSize: 15)),
                  ),

                const SizedBox(height: 32),

                // What's New
                if (latest != null && (latest.changelog.isNotEmpty || latest.changelogEn.isNotEmpty)) ...[
                  const Text("What's New", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
                    child: Text(
                      latest.changelogEn.isNotEmpty ? latest.changelogEn : latest.changelog,
                      style: TextStyle(fontSize: 14, height: 1.6, color: Colors.white.withOpacity(0.8)),
                    ),
                  ),
                  const SizedBox(height: 32),
                ],

                // Releases
                if (versionsAsync.hasError && !versionsAsync.isLoading) ...[
                  _retryCard(
                    'Could not load the release history.',
                    () => ref.invalidate(versionsProvider('app.maharo')),
                  ),
                  const SizedBox(height: 32),
                ],
                if (versions.isNotEmpty) ...[
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Releases', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
                      ),
                      Text('${versions.length}', style: const TextStyle(fontSize: 13, color: _dim)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...versions.asMap().entries.map((entry) => _releaseItem(entry.value, isLatest: entry.key == 0)),
                ],

                const SizedBox(height: 40),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── App State Logic ──

  _AppState _getAppState(InstalledAppInfo? installed, StoreVersion? latest) {
    if (installed == null) return _AppState.notInstalled;
    if (latest == null) return _AppState.upToDate;

    // Compare version codes first
    if (installed.versionCode < latest.versionCode) {
      return _AppState.updateAvailable;
    }

    // Also compare versionName as fallback (in case versionCode is 0 or missing)
    if (installed.versionName.isNotEmpty && latest.versionName.isNotEmpty) {
      if (_compareVersionStrings(installed.versionName, latest.versionName) < 0) {
        return _AppState.updateAvailable;
      }
    }

    return _AppState.upToDate;
  }

  /// Compare two version strings like "1.0.7" vs "1.1.8"
  /// Returns negative if a < b, 0 if equal, positive if a > b
  int _compareVersionStrings(String a, String b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final maxLen = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (int i = 0; i < maxLen; i++) {
      final aVal = i < aParts.length ? aParts[i] : 0;
      final bVal = i < bParts.length ? bParts[i] : 0;
      if (aVal != bVal) return aVal - bVal;
    }
    return 0;
  }

  Widget _actionButton(_AppState state, StoreVersion latest) {
    // If a verified download already sits on disk (finished while the store
    // was backgrounded), every Install/Update/Reinstall action opens it
    // instead of downloading from zero again.
    void Function() guard(void Function() action) {
      return () {
        final dl = ref.read(downloadProvider);
        if (dl.installPending) {
          _autoInstallTried = true;
          _openStoredInstaller();
          return;
        }
        if (dl.canResume) {
          // Interrupted download on disk — continue it instead of
          // restarting from zero.
          _autoInstallTried = false;
          ref.read(downloadProvider.notifier).resumeDownload(
            url: latest.downloadUrl,
            sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
            versionName: latest.versionName,
          );
          return;
        }
        _autoInstallTried = false;
        action();
      };
    }

    switch (state) {
      case _AppState.notInstalled:
        return _primaryButton('Install', Icons.download_rounded, _teal, guard(() {
          ref.read(downloadProvider.notifier).startDownload(
            url: latest.downloadUrl,
            sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
            versionName: latest.versionName,
          );
        }));

      case _AppState.updateAvailable:
        return _primaryButton('Update', Icons.system_update_rounded, const Color(0xFF3B82F6), guard(() async {
          final installedInfo = ref.read(installedVersionProvider('app.maharo')).valueOrNull;
          final installedCode = installedInfo?.versionCode ?? 0;

          // Try a delta patch (fetched fresh through patchProvider)
          if (installedCode > 0) {
            try {
              final patch = await ref.refresh(
                patchProvider((appId: 'app.maharo', fromVersionCode: installedCode)).future,
              );
              if (!mounted) return;
              // Only a patch that rebuilds exactly this release is used.
              if (patch != null && patch.isUsableFor(latest, installedVersionCode: installedCode)) {
                ref.read(downloadProvider.notifier).startDeltaUpdate(
                  patchUrl: patch.patchUrl,
                  patchSha256: patch.patchSha256,
                  fullApkSha256: patch.fullApkSha256,
                  packageName: 'app.maharo',
                  versionName: latest.versionName,
                  fullDownloadUrl: latest.downloadUrl,
                  fullFileSizeBytes: latest.fileSizeBytes,
                );
                return;
              }
            } catch (_) {
              // Patch metadata unavailable — fall through to full download
            }
            if (!mounted) return;
          }

          // No usable patch — full download
          ref.read(downloadProvider.notifier).startDownload(
            url: latest.downloadUrl,
            sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
            versionName: latest.versionName,
          );
        }));

      case _AppState.upToDate:
        return Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => PackageService.openApp('app.maharo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 20),
                  label: const Text('Open', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                onPressed: guard(() {
                  ref.read(downloadProvider.notifier).startDownload(
                    url: latest.downloadUrl,
                    sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
                    versionName: latest.versionName,
                  );
                }),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _dim,
                  side: const BorderSide(color: _dim, width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('Reinstall', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        );
    }
  }

  Widget _primaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        icon: Icon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ── Shared Widgets ──

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
        child: Icon(icon, size: 20, color: _dim),
      ),
    );
  }

  Widget _fallbackIcon() {
    return Container(
      color: _card,
      child: Image.asset('assets/maharo_icon.png', fit: BoxFit.cover),
    );
  }

  Widget _downloadProgress(dynamic dl, {bool resumable = false}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: Text(dl.statusText, style: const TextStyle(fontSize: 14, color: Colors.white))),
              Text('${(dl.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _teal)),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: dl.progress.clamp(0.0, 1.0),
              backgroundColor: const Color(0xFF1C2530),
              color: _teal,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: resumable
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => ref.read(downloadProvider.notifier).clearError(),
                        child: const Text('Cancel', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500)),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          final latest = ref.read(latestVersionProvider('app.maharo')).valueOrNull;
                          if (latest == null) return;
                          ref.read(downloadProvider.notifier).resumeDownload(
                            url: latest.downloadUrl,
                            sha256: latest.sha256.isNotEmpty ? latest.sha256 : null,
                            versionName: latest.versionName,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _teal,
                          foregroundColor: const Color(0xFF04231E),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Resume', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => ref.read(downloadProvider.notifier).cancelDownload(),
                        child: const Text('Cancel', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500)),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => ref.read(downloadProvider.notifier).pauseDownload(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF233042),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: const Icon(Icons.pause_rounded, size: 20),
                        label: const Text('Pause', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _completeBanner() {
    return Container(
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF0D2818),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_rounded, color: Color(0xFF4ADE80), size: 20),
          SizedBox(width: 8),
          Text('Downloaded — Installing...', style: TextStyle(color: Color(0xFF4ADE80), fontSize: 15, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _errorBanner(String msg, VoidCallback onDismiss) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: const Color(0xFF2A1215), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(color: Colors.redAccent, fontSize: 13))),
          GestureDetector(onTap: onDismiss, child: const Icon(Icons.close, size: 16, color: Colors.redAccent)),
        ],
      ),
    );
  }

  /// A load failure the user can retry (instead of a misleading empty state).
  Widget _retryCard(String msg, VoidCallback onRetry) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, color: _dim, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(msg, style: const TextStyle(color: Colors.white, fontSize: 13))),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry', style: TextStyle(color: _teal, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// This Store build has no pinned signer certificate, so the native
  /// installer refuses every install (fail closed). Say so before the user
  /// downloads anything.
  Widget _installsDisabledBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1215),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gpp_bad_outlined, color: Colors.redAccent, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text('Installs are disabled in this Store build',
                    style: TextStyle(color: Colors.redAccent, fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'The trusted Maharo signing certificate was not configured when this '
            'Store was built, so it cannot verify downloads. Please install an '
            'updated Maharo Store.',
            style: TextStyle(color: Color(0xFFE7B8BC), fontSize: 13, height: 1.5),
          ),
          SizedBox(height: 6),
          Text(
            'التثبيت معطّل في هذه النسخة من المتجر لأن شهادة توقيع ماهارو الموثوقة غير مضبوطة. يرجى تثبيت نسخة محدّثة من المتجر.',
            style: TextStyle(color: Color(0xFFC99A9E), fontSize: 12, height: 1.6),
            textDirection: TextDirection.rtl,
          ),
        ],
      ),
    );
  }

  /// Shown when the system installer was opened but the app did not end up
  /// installed. Offers the one-tap migration: remove the old differently-
  /// signed build (with the user's confirmation in the system dialog), after
  /// which the store re-installs the new version automatically.
  /// Download ready but installer not opened yet (typical when the
  /// download finished while the store was backgrounded). One tap opens
  /// the system installer — no re-download needed.
  Widget _installPendingCard({
    required VoidCallback onOpen,
    required VoidCallback onDismiss,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF12211C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF0D9488).withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.download_done_rounded, color: Color(0xFF00BFA5), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Download complete',
                    style: TextStyle(color: Color(0xFF00BFA5), fontSize: 14, fontWeight: FontWeight.w600)),
                SizedBox(height: 3),
                Text('التنزيل جاهز — افتح المثبّت لإكمال التثبيت',
                    style: TextStyle(color: Color(0xFFB9CFC9), fontSize: 12.5)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: onOpen,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFA5),
              foregroundColor: const Color(0xFF04231E),
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Install', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _installBlockedBanner({
    required VoidCallback onDismiss,
    required VoidCallback onRemoveOld,
    bool showManualFallback = false,
    VoidCallback? onOpenSettings,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2113),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFB45309).withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B), size: 18),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Update blocked — old app signature',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              GestureDetector(onTap: onDismiss, child: const Icon(Icons.close, size: 16, color: Color(0xFF92703A))),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Android refused this update because the installed Maharo app uses an old '
            'signing key. Remove it once — your account, progress and purchases are safe '
            'on the server — and the store will install the new version automatically. '
            '(Only offline downloads stored on this phone are removed.)',
            style: TextStyle(color: Color(0xFFE7D6B8), fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            'حظر النظام التحديث لأن التطبيق القديم موقّع بمفتاح مختلف. احذفه مرة واحدة وسيُثبّت المتجر الإصدار الجديد تلقائيًا. بياناتك و تقدّمك محفوظة على الخادم.',
            style: TextStyle(color: Color(0xFFC9B896), fontSize: 12, height: 1.6),
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 12),
          if (showManualFallback && onOpenSettings != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF231A0E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFB45309).withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Still there? Remove it from phone settings:',
                    style: TextStyle(color: Color(0xFFF59E0B), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Some phones block the removal dialog. Open phone settings → '
                    'Maharo → Uninstall, then come back — installation continues automatically.',
                    style: TextStyle(color: Color(0xFFE7D6B8), fontSize: 12.5, height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'بعض الهواتف تمنع حوار الحذف. افتح إعدادات الهاتف ← ماهارو ← إلغاء التثبيت، ثم عد للمتجر — سيُكمل التثبيت تلقائيًا.',
                    style: TextStyle(color: Color(0xFFC9B896), fontSize: 12, height: 1.6),
                    textDirection: TextDirection.rtl,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: onOpenSettings,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFF59E0B),
                      side: const BorderSide(color: Color(0xFFB45309)),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.settings_outlined, size: 17),
                    label: const Text('Open phone settings',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onRemoveOld,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF59E0B),
                    foregroundColor: const Color(0xFF1C1200),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Remove old version',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: onDismiss,
                child: const Text('Later', style: TextStyle(color: Color(0xFF92703A))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _releaseItem(StoreVersion v, {bool isLatest = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: isLatest ? _teal.withOpacity(0.12) : const Color(0xFF1C2530),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isLatest ? Icons.new_releases_rounded : Icons.update_rounded,
              size: 18,
              color: isLatest ? _teal : _dim,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('v${v.versionName}',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isLatest ? _teal : Colors.white)),
                    if (isLatest) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: _teal.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                        child: const Text('LATEST',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: _teal, letterSpacing: 0.8)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmtDate(v.createdAt)}  •  ${(v.fileSizeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  style: const TextStyle(fontSize: 12, color: _dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          const Text('No connection', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
          const SizedBox(height: 6),
          const Text('Check your internet and try again', style: TextStyle(fontSize: 14, color: _dim)),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _refreshAll,
            style: ElevatedButton.styleFrom(backgroundColor: _teal, foregroundColor: Colors.white, elevation: 0),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  static String _fmtDate(DateTime dt) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${m[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

enum _AppState { notInstalled, updateAvailable, upToDate }
