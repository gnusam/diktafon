package cz.mod42.diktafon

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
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
 *
 * While whisper is on a memo the notification also says how far it has got
 * ([update]): the shade is where you look for background work, and a bar
 * that moves is the difference between "still working" and "stuck".
 */
class ProcessingForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "processing"
        // 100/200 are the download notifications (download_notifier.dart),
        // 300 the recording service.
        const val NOTIFICATION_ID = 400
        const val EXTRA_TITLE = "title"
        const val EXTRA_CHANNEL_NAME = "channelName"

        /** True between startForeground and onDestroy — [update] only ever
         *  redraws a notification the service owns; posting one after the
         *  service is gone would leave a stray "Finishing memos" behind. */
        @Volatile private var running = false
        private var title: String = "Finishing memos"

        /** Redraws the ongoing notification with a line of text and, when
         *  known, a determinate bar (percent 0..100). Null text and percent
         *  put it back to the indeterminate "working" it starts with. */
        fun update(context: Context, text: String?, percent: Int?) {
            if (!running) return
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, build(context, title, text, percent))
        }

        private fun build(
            context: Context, title: String, text: String?, percent: Int?
        ): Notification {
            val tapIntent = PendingIntent.getActivity(
                context, 0,
                context.packageManager.getLaunchIntentForPackage(context.packageName),
                PendingIntent.FLAG_IMMUTABLE)
            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentIntent(tapIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
            if (text != null) builder.setContentText(text)
            if (percent != null) {
                // whisper's own figure, once it has one.
                builder.setProgress(100, percent.coerceIn(0, 100), false)
            } else {
                // Indeterminate: the queue knows job counts, not a fraction of
                // one pass — a bar that lied would be worse than none.
                builder.setProgress(0, 0, true)
            }
            return builder.build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        title = intent?.getStringExtra(EXTRA_TITLE) ?: "Finishing memos"
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME) ?: "Processing"

        val manager = getSystemService(NotificationManager::class.java)
        // LOW: no sound, no peek — this is a progress indicator for work the
        // user never asked to watch.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW))

        val notification = build(this, title, null, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
