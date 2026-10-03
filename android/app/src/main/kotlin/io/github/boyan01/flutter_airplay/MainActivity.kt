// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bridge: ReceiverBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        bridge = ReceiverBridge(this, flutterEngine)
    }
    override fun onDestroy() { bridge?.close();bridge=null;super.onDestroy() }
}
