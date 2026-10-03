// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay;
import java.nio.charset.StandardCharsets;
import java.util.Map;
public final class TxtRecordsTest {
    public static void main(String[] args) {
        byte[] valid = {4, 'p', 'k', '=', 0, 3, 'a', '=', (byte)255};
        Map<String, byte[]> records = TxtRecords.parse(valid);
        if (records.get("pk")[0] != 0 || records.get("a")[0] != (byte)255) throw new AssertionError();
        byte[][] bad = {null, {5, 'a'}, {1, '='}};
        for (byte[] bytes : bad) {
            try { TxtRecords.parse(bytes); throw new AssertionError("Invalid TXT accepted"); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("PASS: binary TXT values, truncation and empty-key rejection");
    }
}
