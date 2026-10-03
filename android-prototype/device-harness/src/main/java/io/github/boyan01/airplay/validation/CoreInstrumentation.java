// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay.validation;
import android.app.Instrumentation;
import android.os.Bundle;
public final class CoreInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }
    @Override public void onStart() {
        Bundle results = new Bundle();
        try {
            results.putString("stream", CoreChecks.run(getTargetContext()));
            finish(-1, results);
        } catch (Throwable error) {
            results.putString("stream", "FAIL: " + error.getClass().getSimpleName() + ": " + error.getMessage());
            finish(0, results);
        }
    }
}
