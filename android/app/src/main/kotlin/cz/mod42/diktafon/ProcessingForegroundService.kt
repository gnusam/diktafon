package cz.mod42.diktafon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Fork addition — keep-alive for the *post-recording* pipeline.
 *
 * `RecordingForegroundService` covers the capture. Everything the queue does
 * afterwards (transcribe, gist, WAV→AAC, push to the laptop) runs in the same
 * Flutter process with no such token — and a backgrounded process is a cached
 * process: Android freezes its threads within seconds, so a memo recorded and
 * left behind never finished transcribing, let alone reached the laptop.
 *
 * This dataSync-type service holds the process foreground for exactly as long
 * as the queue has a job in hand (see JobQueue's keep-alive), and nothing
 * longer: dataSync is metered by the OS (six hours a day on Android 14+) and
 * its notification is the honest price of working while you are elsewhere.
 * Same shape as the recording service: capture state lives in Dart, the
 * notification copy arrives pre-localized (a bare Service can't reach
 * gen-l10n), and a service the OS restarts on its own would guard nothing.
 */
class ProcessingForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "processing"
        // 100/200 are the download notifications (download_notifier.dart),
        // 300 the recording service.
        const val NOTIFICATION_ID = 400
        const val EXTRA_TITLE = "title"
        const val EXTRA_CHANNEL_NAME = "channelName"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Finishing memos"
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: "Processing"

        val manager = getSystemService(NotificationManager::class.java)
        // LOW: no sound, no peek — this is a progress indicator for work the
        // user never asked to watch.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW))

        val tapIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE)
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentIntent(tapIntent)
            .setOngoing(true)
            // Indeterminate: the queue knows job counts, not a fraction of
            // one whisper pass — a bar that lied would be worse than none.
            .setProgress(0, 0, true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }
}
