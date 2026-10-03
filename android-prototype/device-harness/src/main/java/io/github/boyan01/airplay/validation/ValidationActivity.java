// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay.validation;
import android.app.Activity;
import android.os.Bundle;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
public final class ValidationActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int)(24 * getResources().getDisplayMetrics().density);
        layout.setPadding(padding, padding, padding, padding);
        TextView result = new TextView(this); result.setTextSize(18);
        result.setText(R.string.scope);
        Button run = new Button(this); run.setText(R.string.run_checks);
        layout.addView(result); layout.addView(run); setContentView(layout);
        run.setOnClickListener(view -> {
            run.setEnabled(false); result.setText(R.string.running);
            new Thread(() -> {
                String report;
                try { report = CoreChecks.run(getApplicationContext()); }
                catch (Throwable error) { report = "FAIL: " + error.getClass().getSimpleName() + ": " + error.getMessage(); }
                final String completed = report;
                runOnUiThread(() -> { result.setText(completed); run.setEnabled(true); });
            }, "airplay-core-checks").start();
        });
    }
}
