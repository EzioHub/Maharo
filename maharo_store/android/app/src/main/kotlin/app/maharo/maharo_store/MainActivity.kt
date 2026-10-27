package app.maharo.maharo_store

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.Parcelable
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "app.maharo.store/packages"

    private companion object {
        /// The only package this store installs.
        const val TARGET_PACKAGE = "app.maharo"
        const val INSTALL_RESULT_ACTION = "app.maharo.store.INSTALL_RESULT"
        /// Our own copy of the session id on the result PendingIntent.
        const val EXTRA_STORE_SESSION_ID = "app.maharo.store.extra.SESSION_ID"
        /// PackageInstaller.ACTION_CONFIRM_INSTALL (a system API constant).
        const val ACTION_CONFIRM_INSTALL = "android.content.pm.action.CONFIRM_INSTALL"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val NO_SESSION = -1
        /// Private staging folder under filesDir; must match
        /// DownloadManager.stagingSubdir in Dart.
        const val STAGING_DIR = "apk"
        const val COPY_BUFFER_BYTES = 64 * 1024
        /// Slack for the post-install lastUpdateTime check.
        const val CLOCK_TOLERANCE_MS = 60_000L
        val SHA256_HEX = Regex("^[0-9a-f]{64}$")
        val KNOWN_SYSTEM_INSTALLERS = setOf(
            "com.android.packageinstaller",
            "com.google.android.packageinstaller"
        )
    }

    /// Install refused before or while preparing the session.
    private class InstallRejected(val code: String) : Exception(code)

    /// A fully written, hash-checked session ready to commit.
    private class PreparedInstall(val sessionId: Int, val versionCode: Long)

    /// True while the store activity is in the foreground. Used to avoid
    /// launching the installer confirm dialog from the background (Android
    /// blocks that) — Dart then re-opens it when the user returns.
    private var isInForeground = false

    override fun onResume() {
        super.onResume()
        isInForeground = true
    }

    override fun onPause() {
        super.onPause()
        isInForeground = false
    }

    private var pendingInstallResult: MethodChannel.Result? = null
    private var installResultReceiver: BroadcastReceiver? = null

    /// Session this store created and committed; results for any other
    /// session id are ignored.
    private var activeSessionId = NO_SESSION
    private var activeVersionCode = -1L
    private var activeCommitStartedAt = 0L
    private var preparingInstall = false

    /// Archive checks, hashing and copying run here, off the main thread.
    private val installExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        installResultReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
            }
        }
        installResultReceiver = null
        installExecutor.shutdown()
        super.onDestroy()
    }

    private fun registerInstallReceiver() {
        if (installResultReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                handleInstallResult(intent)
            }
        }
        // Not exported on every API level. Below Android 13, ContextCompat
        // guards the receiver with this app's signature-level
        // DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION (declared by androidx.core),
        // so other apps cannot deliver forged results. The PackageInstaller
        // result is sent through a PendingIntent this app created, so it
        // still arrives.
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(INSTALL_RESULT_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        installResultReceiver = receiver
    }

    private fun handleInstallResult(intent: Intent) {
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, NO_SESSION)
        val taggedSessionId = intent.getIntExtra(EXTRA_STORE_SESSION_ID, NO_SESSION)
        // Only the session this store committed counts.
        if (sessionId == NO_SESSION || sessionId != taggedSessionId || sessionId != activeSessionId) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> handlePendingUserAction(intent, sessionId)
            PackageInstaller.STATUS_SUCCESS -> {
                // A success only counts when the package manager really shows
                // the version this session installed.
                if (installedMatchesActiveSession()) {
                    finishActiveSession(mapOf("success" to true, "message" to ""))
                } else {
                    finishActiveSession(failure("install_unverified"))
                }
            }
            else -> finishActiveSession(failure("$status: $message"))
        }
    }

    private fun handlePendingUserAction(intent: Intent, sessionId: Int) {
        if (!isInForeground) {
            // Store is in the background: Android forbids showing the dialog
            // now. Report distinctly so the Dart side keeps the verified APK
            // and re-opens the installer (after re-verifying it) when the
            // user returns. A newer install abandons this session.
            val res = pendingInstallResult
            pendingInstallResult = null
            res?.success(failure("pending_user_action_background"))
            return
        }
        val confirm = trustedConfirmIntent(intent, sessionId)
        if (confirm == null) {
            abandonQuietly(sessionId)
            finishActiveSession(failure("confirm_untrusted"))
            return
        }
        try {
            // System confirm dialog (first install / no update ownership).
            // Final verdict arrives in a follow-up broadcast — keep the
            // result pending.
            startActivity(confirm)
        } catch (e: Exception) {
            abandonQuietly(sessionId)
            finishActiveSession(failure("confirm_failed"))
        }
    }

    /// The confirm intent is launched only when it is the platform's
    /// CONFIRM_INSTALL for our session and resolves to a system package
    /// installer. Data, clip data, selectors and URI-grant flags from the
    /// received intent are refused, never forwarded.
    private fun trustedConfirmIntent(result: Intent, sessionId: Int): Intent? {
        val confirm: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            result.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            result.getParcelableExtra<Parcelable>(Intent.EXTRA_INTENT) as? Intent
        }
        if (confirm == null || confirm.action != ACTION_CONFIRM_INSTALL) return null
        if (confirm.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, NO_SESSION) != sessionId) return null
        val grantFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        if (confirm.data != null || confirm.clipData != null || confirm.selector != null ||
            (confirm.flags and grantFlags) != 0
        ) return null
        @Suppress("DEPRECATION")
        val resolved = packageManager.resolveActivity(confirm, 0) ?: return null
        val activity = resolved.activityInfo ?: return null
        if (!isSystemInstaller(activity.packageName, activity.applicationInfo)) return null
        // Launch exactly the component that was checked; never re-resolve.
        return Intent(confirm)
            .setComponent(ComponentName(activity.packageName, activity.name))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun isSystemInstaller(pkg: String, appInfo: ApplicationInfo?): Boolean {
        if (appInfo == null || (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) == 0) return false
        return pkg in KNOWN_SYSTEM_INSTALLERS || pkg in systemInstallerPackages()
    }

    /// Mirrors how the platform picks its installer: the system-only
    /// handler of ACTION_INSTALL_PACKAGE for an APK. Covers OEM installers
    /// (for example com.miui.packageinstaller).
    private fun systemInstallerPackages(): Set<String> {
        @Suppress("DEPRECATION")
        val probe = Intent(Intent.ACTION_INSTALL_PACKAGE)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .setDataAndType(Uri.parse("content://app.maharo.store.probe/probe.apk"), APK_MIME_TYPE)
        @Suppress("DEPRECATION")
        val matches = packageManager.queryIntentActivities(probe, PackageManager.MATCH_SYSTEM_ONLY)
        return matches.mapNotNull { it.activityInfo?.packageName }.toSet()
    }

    private fun installedMatchesActiveSession(): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val info = packageManager.getPackageInfo(TARGET_PACKAGE, 0)
            versionCodeOf(info) == activeVersionCode &&
                info.lastUpdateTime >= activeCommitStartedAt - CLOCK_TOLERANCE_MS
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun finishActiveSession(reply: Map<String, Any>) {
        val res = pendingInstallResult
        pendingInstallResult = null
        activeSessionId = NO_SESSION
        activeVersionCode = -1L
        res?.success(reply)
    }

    private fun failure(code: String): Map<String, Any> = mapOf("success" to false, "message" to code)

    private fun abandonQuietly(sessionId: Int) {
        try {
            packageManager.packageInstaller.abandonSession(sessionId)
        } catch (e: Exception) {
        }
    }

    /// SHA-256 fingerprints of the certificates allowed to sign app.maharo,
    /// injected at build time from MAHARO_ANDROID_TRUSTED_CERT_SHA256.
    /// Empty means installs are refused (fail closed).
    private fun trustedSignerPins(): Set<String> =
        BuildConfig.MAHARO_TRUSTED_APP_CERT_SHA256.split(',')
            .map { it.trim().replace(":", "").lowercase(Locale.ROOT) }
            .filter { SHA256_HEX.matches(it) }
            .toSet()

    private fun isInStagingDir(file: File): Boolean = try {
        val dir = File(filesDir, STAGING_DIR).canonicalFile
        file.canonicalFile.parentFile == dir
    } catch (e: Exception) {
        false
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    @Suppress("DEPRECATION")
    private fun readArchiveInfo(apk: File): PackageInfo? {
        // GET_SIGNATURES makes Android 9/10 collect the archive's
        // certificates at all; GET_SIGNING_CERTIFICATES fills signingInfo
        // on Android 9+.
        var flags = PackageManager.GET_SIGNATURES
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            flags = flags or PackageManager.GET_SIGNING_CERTIFICATES
        }
        return packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
    }

    /// SHA-256 of each current signer certificate (DER), lower-case hex.
    @Suppress("DEPRECATION")
    private fun signerDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            info.signatures
        }
        if (signatures == null || signatures.isEmpty()) return emptySet()
        return signatures.map { toHex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
    }

    private fun toHex(bytes: ByteArray): String {
        val digits = "0123456789abcdef"
        val out = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xff
            out[i * 2] = digits[v ushr 4]
            out[i * 2 + 1] = digits[v and 0x0f]
        }
        return String(out)
    }

    private fun startInstall(apk: File, expectedSha: String, pins: Set<String>, result: MethodChannel.Result) {
        registerInstallReceiver()
        preparingInstall = true
        installExecutor.execute {
            val outcome: Any = try {
                prepareSession(apk, expectedSha, pins)
            } catch (e: InstallRejected) {
                e.code
            } catch (e: Exception) {
                e.message ?: "install failed"
            }
            runOnUiThread { commitPrepared(outcome, result) }
        }
    }

    /// Runs on [installExecutor]. Checks the archive (package name and pinned
    /// signer), then copies it into a new PackageInstaller session while
    /// hashing exactly the bytes the session receives. Any failure abandons
    /// the session.
    private fun prepareSession(apk: File, expectedSha: String, pins: Set<String>): PreparedInstall {
        val archive = readArchiveInfo(apk) ?: throw InstallRejected("apk_unreadable")
        if (archive.packageName != TARGET_PACKAGE) throw InstallRejected("package_mismatch")
        val signers = signerDigests(archive)
        if (signers.isEmpty() || !pins.containsAll(signers)) throw InstallRejected("signer_mismatch")

        val installer = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        // The platform also fails the session if the APK is another package.
        params.setAppPackageName(TARGET_PACKAGE)
        // Update Ownership (Android 14+, API 34): once this store has
        // installed the package, it can own future updates. The API does not
        // exist on Android 12/13, where calling it would throw
        // NoSuchMethodError.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            params.setRequestUpdateOwnership(true)
        }
        val sessionId = installer.createSession(params)
        var keep = false
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            installer.openSession(sessionId).use { session ->
                session.openWrite("maharo-apk", 0, apk.length()).use { out ->
                    FileInputStream(apk).use { input ->
                        val buffer = ByteArray(COPY_BUFFER_BYTES)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            digest.update(buffer, 0, read)
                            out.write(buffer, 0, read)
                        }
                    }
                    session.fsync(out)
                }
            }
            if (toHex(digest.digest()) != expectedSha) throw InstallRejected("sha_mismatch")
            keep = true
            return PreparedInstall(sessionId, versionCodeOf(archive))
        } finally {
            if (!keep) abandonQuietly(sessionId)
        }
    }

    /// Main thread: records the session as the active one and commits it.
    private fun commitPrepared(outcome: Any, result: MethodChannel.Result) {
        preparingInstall = false
        if (outcome !is PreparedInstall) {
            result.success(failure(outcome.toString()))
            return
        }
        if (isDestroyed) {
            abandonQuietly(outcome.sessionId)
            result.success(failure("activity_destroyed"))
            return
        }
        // A newer install replaces any older session still waiting for the
        // user; its result (STATUS_FAILURE_ABORTED) is then ignored.
        val previous = activeSessionId
        if (previous != NO_SESSION && previous != outcome.sessionId) abandonQuietly(previous)
        pendingInstallResult?.success(failure("superseded"))
        pendingInstallResult = result
        activeSessionId = outcome.sessionId
        activeVersionCode = outcome.versionCode
        activeCommitStartedAt = System.currentTimeMillis()
        try {
            val callback = Intent(INSTALL_RESULT_ACTION)
                .setPackage(packageName)
                .putExtra(EXTRA_STORE_SESSION_ID, outcome.sessionId)
            val pendingIntent = PendingIntent.getBroadcast(
                this, outcome.sessionId, callback,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            packageManager.packageInstaller.openSession(outcome.sessionId).use {
                it.commit(pendingIntent.intentSender)
            }
        } catch (e: Exception) {
            abandonQuietly(outcome.sessionId)
            finishActiveSession(failure(e.message ?: "install failed"))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledVersion" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    try {
                        val pm = packageManager
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            pm.getPackageInfo(packageName, 0)
                        }
                        val versionName = info.versionName ?: ""
                        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            info.longVersionCode
                        } else {
                            @Suppress("DEPRECATION")
                            info.versionCode.toLong()
                        }
                        result.success(mapOf("versionName" to versionName, "versionCode" to versionCode))
                    } catch (e: PackageManager.NameNotFoundException) {
                        result.success(null)
                    }
                }
                "openApp" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    val intent = packageManager.getLaunchIntentForPackage(packageName)
                    if (intent != null) {
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "getInstalledApkPath" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    try {
                        val appInfo = packageManager.getApplicationInfo(packageName, 0)
                        result.success(appInfo.sourceDir)
                    } catch (e: PackageManager.NameNotFoundException) {
                        result.success(null)
                    }
                }
                // Epoch millis of the last install/update of the package, or 0
                // when not installed. The store compares this before/after the
                // system installer to detect failed installs (e.g. signature
                // conflicts) even when old and new builds share a versionCode.
                "getLastUpdateTime" -> {
                    val packageName = call.argument<String>("packageName") ?: ""
                    try {
                        val pm = packageManager
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            pm.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
                        } else {
                            @Suppress("DEPRECATION")
                            pm.getPackageInfo(packageName, 0)
                        }
                        result.success(info.lastUpdateTime)
                    } catch (e: PackageManager.NameNotFoundException) {
                        result.success(0L)
                    }
                }
                // Open Android's uninstall confirmation dialog for a package
                // (user still confirms — this is NOT a silent uninstall).
                "requestUninstall" -> {
                    val pkg = call.argument<String>("packageName") ?: ""
                    if (pkg.isBlank()) {
                        result.success(false)
                    } else {
                        try {
                            val intent = Intent(Intent.ACTION_DELETE, Uri.parse("package:$pkg"))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                // Whether a signer certificate is pinned in this build. Without
                // one every install is refused (fail closed).
                "getInstallPolicy" -> {
                    result.success(mapOf("signerPinConfigured" to trustedSignerPins().isNotEmpty()))
                }
                "installPackage" -> {
                    val apkPath = call.argument<String>("apkPath") ?: ""
                    val expectedSha = (call.argument<String>("sha256") ?: "").trim().lowercase(Locale.ROOT)
                    val pins = trustedSignerPins()
                    val apk = File(apkPath)
                    when {
                        pins.isEmpty() -> result.success(failure("signer_pin_missing"))
                        !SHA256_HEX.matches(expectedSha) -> result.success(failure("bad_sha256"))
                        apkPath.isBlank() || !apk.isFile || !isInStagingDir(apk) ->
                            result.success(failure("APK file not found"))
                        preparingInstall -> result.success(failure("install_in_progress"))
                        else -> startInstall(apk, expectedSha, pins, result)
                    }
                }
                "startDownloadService" -> {
                    try {
                        val intent = Intent(this, DownloadService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopDownloadService" -> {
                    stopService(Intent(this, DownloadService::class.java))
                    result.success(true)
                }
                "openAppDetails" -> {
                    val pkg = call.argument<String>("packageName") ?: ""
                    if (pkg.isBlank()) {
                        result.success(false)
                    } else {
                        try {
                            // Opens the system App Info page for the package —
                            // the universal manual fallback when an OEM ROM
                            // (MIUI, OneUI, EMUI…) refuses the uninstall dialog.
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}

/// Foreground service that keeps the store's download process alive while
/// the app is backgrounded. Progress is shown in the store UI; this
/// notification simply tells Android "don't freeze me — I'm transferring".
class DownloadService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    "maharo_download",
                    "Downloads",
                    NotificationManager.IMPORTANCE_LOW
                )
                manager.createNotificationChannel(channel)
                Notification.Builder(this, "maharo_download")
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle("Maharo Store")
                    .setContentText("Downloading update…")
                    .setOngoing(true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setSmallIcon(android.R.drawable.stat_sys_download)
                    .setContentTitle("Maharo Store")
                    .setContentText("Downloading update…")
                    .setOngoing(true)
                    .build()
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1001, notification)
        }
        return START_NOT_STICKY
    }
}
