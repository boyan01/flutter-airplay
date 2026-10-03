// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var host: PlaybackHost? = null
    private var events: EventChannel.EventSink? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        host=PlaybackHost(this,flutterEngine.renderer) { events?.success(it) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger,"flutter_airplay/events").setStreamHandler(object:EventChannel.StreamHandler {
            override fun onListen(arguments:Any?,sink:EventChannel.EventSink) { events=sink }
            override fun onCancel(arguments:Any?) { events=null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"flutter_airplay/control").setMethodCallHandler { call,result ->
            when(call.method) {
                "start" -> host!!.start(call.argument<String>("name")?:"Flutter AirPlay Android",result)
                "stop" -> host!!.stop(result)
                else -> result.notImplemented()
            }
        }
    }
    override fun onDestroy() { host?.close();host=null;events=null;super.onDestroy() }
}
