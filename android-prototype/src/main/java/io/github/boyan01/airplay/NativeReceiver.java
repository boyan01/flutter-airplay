// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

/** Receive boundary only. Construct/close on an owned worker, not the UI thread.
 * Binding does not mean discovery or playback is ready. */
public final class NativeReceiver implements AutoCloseable {
    static { System.loadLibrary("airplay_receiver"); }
    private long handle;
    private final String name, raopName;
    public NativeReceiver(String name, byte[] appIdentity, File privateKeyFile) throws IOException {
        if (name == null || name.isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 48)
            throw new IllegalArgumentException("Receiver name must contain 1–48 UTF-8 bytes");
        if (appIdentity == null || appIdentity.length != 6)
            throw new IllegalArgumentException("Use a persisted random six-byte app identity");
        if (privateKeyFile == null) throw new IllegalArgumentException("Private app key path required");
        StringBuilder prefix = new StringBuilder();
        for (byte b : appIdentity) prefix.append(String.format(java.util.Locale.ROOT, "%02X", b & 255));
        this.name = name; this.raopName = prefix + "@" + name;
        handle = open(name, appIdentity, privateKeyFile.getAbsolutePath());
        if (handle == 0) throw new IOException("Native receiver failed to bind");
    }
    public synchronized int port() { requireOpen(); return (int)(handle & 0xffff); }
    public String name() { return name; }
    public String raopName() { return raopName; }
    public synchronized Map<String, byte[]> txt(boolean raop) {
        requireOpen(); return TxtRecords.parse(txtNative(handle, raop));
    }
    public synchronized EncodedPacket poll() { requireOpen(); return pollNative(handle); }
    public synchronized long epoch() { requireOpen(); return epochNative(handle); }
    private void requireOpen() { if (handle == 0) throw new IllegalStateException("Receiver closed"); }
    @Override public synchronized void close() {
        if (handle != 0) { closeNative(handle); handle = 0; }
    }
    private static native long open(String name, byte[] identity, String privateKeyFile);
    private static native void closeNative(long handle);
    private static native byte[] txtNative(long handle, boolean raop);
    private static native EncodedPacket pollNative(long handle);
    private static native long epochNative(long handle);
}
