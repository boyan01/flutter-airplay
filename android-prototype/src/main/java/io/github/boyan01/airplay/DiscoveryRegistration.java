// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.boyan01.airplay;
import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Explicit opt-in discovery. Construct only after a playback sink is prepared. */
public final class DiscoveryRegistration implements AutoCloseable {
    public interface Listener {
        void onRegistered(String airplayName, String raopName);
        void onFailure(String operation, int code);
    }
    private final NsdManager manager;
    private final Listener listener;
    private final List<Entry> entries = new ArrayList<>();
    private boolean closed;
    public DiscoveryRegistration(Context context, NativeReceiver receiver, Listener listener) {
        this.manager = (NsdManager)context.getApplicationContext().getSystemService(Context.NSD_SERVICE);
        this.listener = listener;
        if (manager == null || listener == null) throw new IllegalArgumentException("NSD and listener required");
        entries.add(new Entry(receiver.name(), "_airplay._tcp", receiver.port(), receiver.txt(false)));
        entries.add(new Entry(receiver.raopName(), "_raop._tcp", receiver.port(), receiver.txt(true)));
        try {
            for (Entry entry : entries) manager.registerService(entry.info, NsdManager.PROTOCOL_DNS_SD, entry);
        } catch (RuntimeException e) { close(); throw e; }
    }
    private synchronized void registered(Entry entry, NsdServiceInfo info) {
        entry.registered = true; entry.actualName = info.getServiceName();
        if (closed) { unregister(entry); return; }
        if (entries.get(0).registered && entries.get(1).registered)
            listener.onRegistered(entries.get(0).actualName, entries.get(1).actualName);
    }
    private void unregister(Entry entry) {
        if (!entry.registered || entry.unregistering) return;
        entry.unregistering = true;
        try { manager.unregisterService(entry); }
        catch (RuntimeException e) {
            entry.unregistering = false;
            listener.onFailure("unregister", NsdManager.FAILURE_INTERNAL_ERROR);
        }
    }
    @Override public synchronized void close() {
        closed = true;
        for (Entry entry : entries) unregister(entry);
        // Pending registrations are unregistered by their late success callbacks.
    }
    private final class Entry implements NsdManager.RegistrationListener {
        final NsdServiceInfo info = new NsdServiceInfo();
        boolean registered, unregistering;
        String actualName;
        Entry(String name, String type, int port, Map<String, byte[]> txt) {
            info.setServiceName(name); info.setServiceType(type); info.setPort(port);
            for (Map.Entry<String, byte[]> item : txt.entrySet()) info.setAttribute(item.getKey(), new String(item.getValue(), java.nio.charset.StandardCharsets.UTF_8));
        }
        @Override public void onServiceRegistered(NsdServiceInfo info) { registered(this, info); }
        @Override public void onRegistrationFailed(NsdServiceInfo info, int code) {
            synchronized (DiscoveryRegistration.this) {
                if (!closed) { close(); listener.onFailure("register", code); }
            }
        }
        @Override public void onServiceUnregistered(NsdServiceInfo info) {
            synchronized (DiscoveryRegistration.this) { registered = false; unregistering = false; }
        }
        @Override public void onUnregistrationFailed(NsdServiceInfo info, int code) {
            synchronized (DiscoveryRegistration.this) {
                unregistering = false; listener.onFailure("unregister", code);
            }
        }
    }
}
