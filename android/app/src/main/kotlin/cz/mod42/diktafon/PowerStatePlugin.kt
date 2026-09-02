package cz.mod42.diktafon

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Fork addition — what the battery is doing, as a stream.
 *
 * The job queue suspends whisper and the LLM below a threshold on battery
 * (never the upload: pushing a finished memo costs a rounding error next to
 * an inference pass). For that it needs two things — the state now, and to
 * be told when it changes, so a phone put on the charger picks its backlog
 * up on its own instead of waiting for the next app launch.
 *
 * `ACTION_BATTERY_CHANGED` is a sticky broadcast that cannot be declared in
 * a manifest, only registered at runtime; registering returns the current
 * value immediately, which is why the stream needs no separate getter — the
 * first event arrives with the subscription.
 */
class PowerStatePlugin(messenger: BinaryMessenger, private val context: Context) {
    companion object {
        const val CHANNEL = "diktafon/power"
    }

    private var receiver: BroadcastReceiver? = null

    init {
        EventChannel(messenger, CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val handler = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            intent?.let { events.success(readState(it)) }
                        }
                    }
                    receiver = handler
                    // The sticky intent comes back from the registration
                    // itself: the queue knows where it stands before the
                    // first level change, with no extra round trip.
                    val sticky = context.registerReceiver(
                        handler, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                    sticky?.let { events.success(readState(it)) }
                }

                override fun onCancel(arguments: Any?) {
                    receiver?.let {
                        // Unregistering an already-dead receiver throws; a
                        // teardown race must not take the app with it.
                        try {
                            context.unregisterReceiver(it)
                        } catch (e: IllegalArgumentException) {
                        }
                    }
                    receiver = null
                }
            })
    }

    /** Called from the activity's own teardown, for the stream nobody closed. */
    fun dispose() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (e: IllegalArgumentException) {
            }
        }
        receiver = null
    }

    private fun readState(intent: Intent): Map<String, Any> {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        // An unreadable gauge must not be read as an empty one: -1 means
        // "no opinion", and the Dart side lets the work through.
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        // EXTRA_PLUGGED, not BATTERY_STATUS_CHARGING: what the gate cares
        // about is "is it on a cable", and a battery sitting at 100 % on
        // mains reports FULL rather than CHARGING.
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
        return mapOf("level" to percent, "charging" to plugged)
    }
}
