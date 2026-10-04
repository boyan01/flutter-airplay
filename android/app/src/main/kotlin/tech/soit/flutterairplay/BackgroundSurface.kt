// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.FutureTask

/** Drains decoded images while the Activity has no visible SurfaceView. */
internal class BackgroundSurface : AutoCloseable {
    private val thread = HandlerThread("AirPlayBackgroundVideo").apply { start() }
    private val handler = Handler(thread.looper)
    private var display = EGL14.EGL_NO_DISPLAY
    private var context = EGL14.EGL_NO_CONTEXT
    private var target = EGL14.EGL_NO_SURFACE
    private var texture: SurfaceTexture? = null
    private var textureName = 0
    private var output: Surface? = null
    private var closed = false
    val surface: Surface get() = checkNotNull(output)

    init {
        try {
            onThread {
                display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
                val version = IntArray(2)
                check(EGL14.eglInitialize(display, version, 0, version, 1)) { "Cannot initialize background EGL" }
                val attributes = intArrayOf(EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_NONE)
                val configs = arrayOfNulls<EGLConfig>(1)
                val count = IntArray(1)
                check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0)
                context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
                    intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
                target = EGL14.eglCreatePbufferSurface(display, configs[0],
                    intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
                check(EGL14.eglMakeCurrent(display, target, target, context)) { "Cannot bind background EGL" }
                val names = IntArray(1)
                GLES20.glGenTextures(1, names, 0)
                textureName = names[0]
                texture = SurfaceTexture(textureName).also { image ->
                    image.setOnFrameAvailableListener({
                        if (!closed) {
                            try { image.updateTexImage() }
                            catch (error: RuntimeException) { Log.w("AirPlayPlayer", "Background image update failed", error) }
                        }
                    }, handler)
                    output = Surface(image)
                }
            }
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    private fun onThread(action: () -> Unit) {
        val task = FutureTask { action() }
        check(handler.post(task)) { "Background video thread stopped" }
        task.get()
    }

    override fun close() {
        onThread {
            closed = true
            output?.release(); output = null
            texture?.setOnFrameAvailableListener(null)
            texture?.release(); texture = null
            if (textureName != 0) GLES20.glDeleteTextures(1, intArrayOf(textureName), 0)
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (target != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, target)
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                EGL14.eglReleaseThread()
                EGL14.eglTerminate(display)
            }
        }
        thread.quitSafely()
        thread.join()
    }
}
