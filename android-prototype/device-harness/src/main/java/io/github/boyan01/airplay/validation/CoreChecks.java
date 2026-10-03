// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay.validation;
import android.content.Context;
import io.github.boyan01.airplay.NativeReceiver;
import java.io.File;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

final class CoreChecks {
    static String run(Context context) throws Exception {
        byte[] identity = new byte[6]; new SecureRandom().nextBytes(identity);
        identity[0] = (byte)((identity[0] & 0xfe) | 0x02);
        File key = new File(context.getCacheDir(), "validation-pairing.key");
        try {
            for (int session = 0; session < 3; session++) {
                NativeReceiver receiver = new NativeReceiver("Synthetic Android core", identity, key);
                try {
                    if (receiver.port() <= 0 || !receiver.txt(true).containsKey("pk")
                        || !receiver.txt(false).containsKey("features")) throw new AssertionError("Core bind/TXT failed");
                    String info = request(receiver.port(), "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n");
                    if (!info.contains("200 OK") || !info.contains("application/x-apple-binary-plist"))
                        throw new AssertionError("/info response failed");
                    String options = request(receiver.port(), "OPTIONS * RTSP/1.0\r\nCSeq: 2\r\n\r\n");
                    if (!options.contains("200 OK") || !options.contains("Public:"))
                        throw new AssertionError("OPTIONS response failed");
                    if (receiver.poll() != null || receiver.epoch() < 0) throw new AssertionError("Queue/epoch failed");
                    try {
                        new NativeReceiver("duplicate", identity, key);
                        throw new AssertionError("Duplicate process receiver accepted");
                    } catch (java.io.IOException expected) { }
                } finally { receiver.close(); receiver.close(); }
                try { receiver.poll(); throw new AssertionError("Closed poll accepted"); }
                catch (IllegalStateException expected) { }
            }
            return "PASS: JNI load, UxPlay /info + OPTIONS, TXT, 3 sessions, duplicate start and closed-state checks.\n"
                + "Synthetic protocol input only. No iPhone, discovery, decoder, image or sound validation.";
        } finally { if (key.exists() && !key.delete()) throw new java.io.IOException("Test key cleanup failed"); }
    }
    private static String request(int port, String request) throws Exception {
        try (Socket socket = new Socket("127.0.0.1", port)) {
            socket.setSoTimeout(3000);
            socket.getOutputStream().write(request.getBytes(StandardCharsets.US_ASCII));
            byte[] bytes = new byte[16384]; int size = socket.getInputStream().read(bytes);
            if (size <= 0) throw new AssertionError("Empty native response");
            return new String(bytes, 0, size, StandardCharsets.ISO_8859_1);
        }
    }
}
