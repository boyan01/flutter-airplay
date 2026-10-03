// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.video_regression

import android.app.Instrumentation
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.github.jqssun.airplay.renderer.EglCore
import io.github.jqssun.airplay.renderer.VideoPipeline
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/** Exercises resizing the same output Surface, as Flutter does on rotation. */
class VideoPipelineRegression : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            result.putString("pixels", resizedSurfacePixels())
            result.putString("verdict", "PASS: portrait, landscape and portrait buffers retain complete image coverage")
            finish(0, result)
        } catch (error: Throwable) {
            result.putString("verdict", "FAIL: ${error.message}")
            result.putString("error", android.util.Log.getStackTraceString(error))
            finish(1, result)
        }
    }

    private fun resizedSurfacePixels(): String {
        val callbacks = HandlerThread("VideoRegressionFrames").apply { start() }
        val ready = Semaphore(0)
        val consumer = EglCore()
        val textures = IntArray(2)
        GLES20.glGenTextures(2, textures, 0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        val output = SurfaceTexture(textures[0])
        output.setDefaultBufferSize(64, 128)
        output.setOnFrameAvailableListener({ ready.release() }, Handler(callbacks.looper))
        val surface = Surface(output)
        val pipeline = VideoPipeline()
        val framebuffer = IntArray(1)
        GLES20.glGenFramebuffers(1, framebuffer, 0)
        val program = program()
        val position = GLES20.glGetAttribLocation(program, "position")
        val matrix = GLES20.glGetUniformLocation(program, "matrix")
        val vertices = ByteBuffer.allocateDirect(8 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)); position(0)
        }
        val transform = FloatArray(16)
        val samples = mutableListOf<String>()
        try {
            pipeline.setVideoSize(64, 128)
            pipeline.setDisplaySurface(surface)
            pipeline.start()
            val input = checkNotNull(pipeline.inputSurface)
            for ((width, height) in listOf(64 to 128, 128 to 64, 64 to 128)) {
                output.setDefaultBufferSize(width, height)
                pipeline.setVideoSize(width, height)
                // EGL may notice a resized native window on its next buffer swap.
                repeat(3) {
                    val canvas = input.lockCanvas(null)
                    canvas.drawColor(Color.RED)
                    input.unlockCanvasAndPost(canvas)
                    check(ready.tryAcquire(5, TimeUnit.SECONDS)) { "No rendered frame at ${width}x${height}" }
                    consumer.makeCurrent()
                    output.updateTexImage()
                }
                output.getTransformMatrix(transform)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, textures[1])
                GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height, 0,
                    GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer[0])
                GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                    GLES20.GL_TEXTURE_2D, textures[1], 0)
                check(GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) == GLES20.GL_FRAMEBUFFER_COMPLETE)
                GLES20.glViewport(0, 0, width, height)
                GLES20.glUseProgram(program)
                GLES20.glUniformMatrix4fv(matrix, 1, false, transform, 0)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textures[0])
                GLES20.glEnableVertexAttribArray(position)
                GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices)
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                val pixels = ByteBuffer.allocateDirect(width * height * 4)
                GLES20.glReadPixels(0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
                var red = 0
                for (index in 0 until width * height) {
                    val offset = index * 4
                    if ((pixels.get(offset).toInt() and 255) >= 240 &&
                        (pixels.get(offset + 1).toInt() and 255) <= 15 &&
                        (pixels.get(offset + 2).toInt() and 255) <= 15) red++
                }
                samples.add("${width}x${height}: $red/${width * height} red pixels")
                check(red >= width * height * 0.99) {
                    "Resized video lost image coverage: ${samples.joinToString("; ")}"
                }
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            }
        } finally {
            pipeline.release()
            consumer.makeCurrent()
            surface.release()
            output.release()
            GLES20.glDeleteProgram(program)
            GLES20.glDeleteFramebuffers(1, framebuffer, 0)
            GLES20.glDeleteTextures(2, textures, 0)
            consumer.close()
            callbacks.quitSafely()
            callbacks.join()
        }
        return samples.joinToString("; ")
    }

    private fun program(): Int {
        fun shader(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val compiled = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
            check(compiled[0] != 0) { GLES20.glGetShaderInfoLog(shader) }
            return shader
        }
        val vertex = shader(GLES20.GL_VERTEX_SHADER, """
            attribute vec2 position;
            uniform mat4 matrix;
            varying highp vec2 tex;
            void main() {
                gl_Position = vec4(position, 0.0, 1.0);
                tex = (matrix * vec4(position * 0.5 + 0.5, 0.0, 1.0)).xy;
            }
        """.trimIndent())
        val fragment = shader(GLES20.GL_FRAGMENT_SHADER, """
            #extension GL_OES_EGL_image_external : require
            precision highp float;
            varying highp vec2 tex;
            uniform samplerExternalOES image;
            void main() { gl_FragColor = texture2D(image, tex); }
        """.trimIndent())
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertex)
        GLES20.glAttachShader(program, fragment)
        GLES20.glLinkProgram(program)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
        check(linked[0] != 0) { GLES20.glGetProgramInfoLog(program) }
        return program
    }
}
