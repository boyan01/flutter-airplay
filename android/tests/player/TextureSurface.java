// SPDX-License-Identifier: GPL-3.0-only
package tech.soit.flutterairplay.player_regression;
import android.graphics.SurfaceTexture;
import android.view.Surface;
import android.opengl.*;
import java.nio.*;

// Test-only GLES consumer, matching Flutter's GPU SurfaceTexture path.
final class TextureSurface implements AutoCloseable {
    private final EGLDisplay display;
    private final EGLContext context;
    private final EGLSurface target;
    private final SurfaceTexture texture;
    final Surface surface;
    private final int textureName, program;
    TextureSurface(int width, int height) {
        display=EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version=new int[2]; EGL14.eglInitialize(display,version,0,version,1);
        int[] attributes={EGL14.EGL_RENDERABLE_TYPE,EGL14.EGL_OPENGL_ES2_BIT,EGL14.EGL_SURFACE_TYPE,EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_RED_SIZE,8,EGL14.EGL_GREEN_SIZE,8,EGL14.EGL_BLUE_SIZE,8,EGL14.EGL_ALPHA_SIZE,8,EGL14.EGL_NONE};
        EGLConfig[] configs=new EGLConfig[1]; int[] count=new int[1];
        EGL14.eglChooseConfig(display,attributes,0,configs,0,1,count,0);
        if(count[0]==0)throw new IllegalStateException("No GLES test configuration");
        context=EGL14.eglCreateContext(display,configs[0],EGL14.EGL_NO_CONTEXT,new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION,2,EGL14.EGL_NONE},0);
        target=EGL14.eglCreatePbufferSurface(display,configs[0],new int[]{EGL14.EGL_WIDTH,16,EGL14.EGL_HEIGHT,16,EGL14.EGL_NONE},0);
        if(!EGL14.eglMakeCurrent(display,target,target,context))throw new IllegalStateException("GLES context failed");
        int[] names=new int[1];GLES20.glGenTextures(1,names,0);textureName=names[0];
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,textureName);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_MIN_FILTER,GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_MAG_FILTER,GLES20.GL_LINEAR);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_WRAP_S,GLES20.GL_CLAMP_TO_EDGE);
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,GLES20.GL_TEXTURE_WRAP_T,GLES20.GL_CLAMP_TO_EDGE);
        texture=new SurfaceTexture(textureName);texture.setDefaultBufferSize(width,height);surface=new Surface(texture);
        int vertex=shader(GLES20.GL_VERTEX_SHADER,"attribute vec2 position; varying vec2 uv; void main(){gl_Position=vec4(position,0.,1.);uv=position*.5+.5;}");
        int fragment=shader(GLES20.GL_FRAGMENT_SHADER,"#extension GL_OES_EGL_image_external : require\nprecision mediump float; varying vec2 uv; uniform samplerExternalOES image; void main(){gl_FragColor=texture2D(image,uv);}");
        program=GLES20.glCreateProgram();GLES20.glAttachShader(program,vertex);GLES20.glAttachShader(program,fragment);GLES20.glLinkProgram(program);
        GLES20.glDeleteShader(vertex);GLES20.glDeleteShader(fragment);
    }
    private int shader(int type,String source){
        int shader=GLES20.glCreateShader(type);GLES20.glShaderSource(shader,source);GLES20.glCompileShader(shader);
        int[] status=new int[1];GLES20.glGetShaderiv(shader,GLES20.GL_COMPILE_STATUS,status,0);
        if(status[0]==0)throw new IllegalStateException(GLES20.glGetShaderInfoLog(shader));return shader;
    }
    void checkRedPixels(){
        checkPixels(255,0,0);
    }
    void checkBluePixels(){
        checkPixels(0,0,255);
    }
    void checkGreenPixels(){
        checkPixels(0,255,0);
    }
    private void bind(){
        if(!EGL14.eglMakeCurrent(display,target,target,context))throw new IllegalStateException("Cannot bind texture consumer");
    }
    long sampleTimestamp(){
        bind();
        texture.updateTexImage();
        return texture.getTimestamp();
    }
    private void checkPixels(int red, int green, int blue){
        bind();
        texture.updateTexImage();
        if(texture.getTimestamp()==0)throw new IllegalStateException("GPU Surface has no decoded image");
        FloatBuffer vertices=ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer();
        vertices.put(new float[]{-1,-1,1,-1,-1,1,1,1}).position(0);
        GLES20.glViewport(0,0,16,16);GLES20.glUseProgram(program);
        int position=GLES20.glGetAttribLocation(program,"position");GLES20.glEnableVertexAttribArray(position);
        GLES20.glVertexAttribPointer(position,2,GLES20.GL_FLOAT,false,0,vertices);
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0);GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,textureName);
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program,"image"),0);GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4);
        ByteBuffer pixel=ByteBuffer.allocateDirect(4);GLES20.glReadPixels(8,8,1,1,GLES20.GL_RGBA,GLES20.GL_UNSIGNED_BYTE,pixel);
        if(Math.abs((pixel.get(0)&255)-red)>55 || Math.abs((pixel.get(1)&255)-green)>30 || Math.abs((pixel.get(2)&255)-blue)>55)
            throw new IllegalStateException("GPU pixels do not match fixture color");
    }
    @Override public void close(){
        bind();
        surface.release();texture.release();GLES20.glDeleteTextures(1,new int[]{textureName},0);GLES20.glDeleteProgram(program);
        EGL14.eglMakeCurrent(display,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_SURFACE,EGL14.EGL_NO_CONTEXT);
        EGL14.eglDestroySurface(display,target);EGL14.eglDestroyContext(display,context);EGL14.eglTerminate(display);
    }
}
