// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
final class TxtRecords {
    static Map<String, byte[]> parse(byte[] wire) {
        if (wire == null) throw new IllegalArgumentException("Missing TXT record");
        Map<String, byte[]> result = new LinkedHashMap<>();
        for (int pos = 0; pos < wire.length;) {
            int n = wire[pos++] & 255, end = pos + n;
            if (end > wire.length) throw new IllegalArgumentException("Truncated TXT record");
            int eq = pos;
            while (eq < end && wire[eq] != '=') eq++;
            if (eq == pos) throw new IllegalArgumentException("Empty TXT key");
            String key = new String(wire, pos, eq - pos, StandardCharsets.US_ASCII);
            result.put(key, Arrays.copyOfRange(wire, eq < end ? eq + 1 : end, end));
            pos = end;
        }
        return result;
    }
}
