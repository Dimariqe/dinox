using Dino;
using GLib;
using Dino.Entities;
using Gee;

namespace Dino.Plugins.TorManager {

    public class TorManager : Object, StreamInteractionModule {
        public const string IDENTITY_STRING = "tor-manager";
        public static ModuleIdentity<TorManager> IDENTITY = new ModuleIdentity<TorManager>(IDENTITY_STRING);

        public string id { get { return IDENTITY_STRING; } }


        public TorController controller { get; private set; }
        public bool is_enabled { get; private set; default = false; }
        public bool use_bridges { get; private set; default = true; }
        public bool force_firewall_ports { get; private set; default = true; }
        private StreamInteractor stream_interactor;
        private Database db;
        private bool is_shutting_down = false;
        private bool is_starting_up = false;  // True during initial restore_state → start_tor sequence
        private bool is_transitioning = false; // Reentrancy guard for set_enabled / restart cycles
        private int retry_count = 0;
        private const int MAX_RETRIES = 2;

        // Fallback bridges to bootstrap connection if blocked
        // These are well-known public bridges from the Tor Project (updated for 2026)
        private const string BOOTSTRAP_BRIDGES = """# Default Bootstrap Bridges (obfs4 + webtunnel)
# obfs4 bridges (widely supported)
obfs4 192.95.36.142:443 CDF2E852BF539B82BC10E27E9115A342BCFE8D62 cert=qUVQ0srPh0AB0BWo1f8Ykkl8m7AzCfSKgfpJVVf9c7iFM/UI0+HDm/9VJiCJROJXIMb4qw iat-mode=0
obfs4 38.229.1.78:80 C8CBDB2464FC9804A69531437BCF2BE31FDD2EE4 cert=Hmyfd2ev46gGY7NoVxA9ngrPF2zCZtzskRTzoWXbxNkzeVnGFPWmrTtILRyqCTjHR+s9dg iat-mode=0
# webtunnel bridges (HTTPS-disguised, harder to detect)
webtunnel 192.95.36.142:443 CDF2E852BF539B82BC10E27E9115A342BCFE8D62 url=https://d3pyku35rn5w83.cloudfront.net/index.html ver=0.0.1
""";

        public TorManager(StreamInteractor stream_interactor, Database db) {
            this.stream_interactor = stream_interactor;
            this.db = db;
            controller = new TorController();
            controller.process_exited.connect(on_process_exited);
            controller.bootstrap_status.connect((percent, summary) => {
                if (percent >= 100) {
                    debug("TorManager: Tor fully bootstrapped. Resetting retry count.");
                    retry_count = 0;
                }
            });
            
            this.stream_interactor.account_added.connect(on_account_added);

            // Restore state
            restore_state();
        }

        private bool is_standalone_socks5(Account account) {
            // A standalone SOCKS5 proxy points to a real external server,
            // not Tor's own address (127.0.0.1 on a Tor port).
            if (account.proxy_type != "socks5") return false;
            string h = account.proxy_host ?? "";
            int p = account.proxy_port;
            bool is_localhost = (h == "127.0.0.1" || h == "localhost" || h == "::1");
            bool is_tor_port = (p == 9050 || p == 9150 || (p >= 9100 && p <= 9200));
            if (is_localhost && is_tor_port) {
                // Points to Tor's own proxy — leftover from old code, not standalone
                return false;
            }
            return true;
        }

        private void on_account_added(Account account) {
            if (is_enabled) {
                // Skip accounts with a real standalone SOCKS5 proxy
                if (is_standalone_socks5(account)) {
                    debug("TorManager: New account %s has standalone SOCKS5 proxy, not overriding with Tor",
                           account.bare_jid.to_string());
                    return;
                }

                // Always set proxy settings so the first connection attempt goes through Tor.
                // If Tor isn't ready yet, the connection will fail and retry.
                int port = controller.socks_port;
                debug("TorManager: New account added (%s). Setting proxy to 127.0.0.1:%d (Tor running: %s)",
                       account.bare_jid.to_string(), port, controller.is_running.to_string());
                account.proxy_type = "tor";
                account.proxy_host = "127.0.0.1";
                account.proxy_port = port;
            }
        }

        public void prepare_shutdown() {
            is_shutting_down = true;
        }

        private void restore_state() {
            bool bridges_exist = false;

            foreach (var row in db.settings.select()) {
                string key = row[db.settings.key];
                string? val = row[db.settings.value];
                
                if (key == "tor_manager_enabled") {
                    debug("TorManager: restore_state() - DB value for 'tor_manager_enabled': %s", val ?? "null");
                    if (val == "true") {
                        is_enabled = true;
                    }
                } else if (key == "tor_manager_bridges") {
                    bridges_exist = true;
                    if (val != null) {
                        controller.bridge_lines = val;
                    }
                } else if (key == "tor_manager_use_bridges") {
                    if (val == "true") use_bridges = true;
                    else if (val == "false") use_bridges = false;
                } else if (key == "tor_manager_firewall_ports") {
                    if (val == "true") force_firewall_ports = true;
                    else if (val == "false") force_firewall_ports = false;
                }
            }
            
            // Sync controller
            controller.use_bridges = use_bridges;
            controller.force_firewall_ports = force_firewall_ports;

            // If bridges are not set in DB (first run), populate with bootstrap bridges
            if (!bridges_exist) {
                    controller.bridge_lines = BOOTSTRAP_BRIDGES;
                    db.settings.upsert()
                        .value(db.settings.key, "tor_manager_bridges", true)
                        .value(db.settings.value, BOOTSTRAP_BRIDGES)
                        .perform();
            }

            // One-time migration: old code used proxy_type="socks5" + localhost for Tor.
            // New code uses proxy_type="tor". Migrate old entries so cleanup works correctly.
            bool migration_done = db.settings.select().with(db.settings.key, "=", "tor_socks5_migration_done").count() > 0;
            if (!migration_done) {
                foreach (var mig_row in db.account.select()) {
                    string mig_type = mig_row[db.account.proxy_type];
                    if (mig_type == "socks5") {
                        string mig_host = mig_row[db.account.proxy_host] ?? "";
                        int mig_port = mig_row[db.account.proxy_port];
                        bool is_localhost = (mig_host == "127.0.0.1" || mig_host == "localhost" || mig_host == "::1");
                        bool is_tor_port = (mig_port == 9050 || mig_port == 9150 || (mig_port >= 9100 && mig_port <= 9200));
                        if (is_localhost && is_tor_port) {
                            debug("TorManager: Migrating old socks5+localhost to 'tor' for account ID %d", mig_row[db.account.id]);
                            db.account.update()
                                .set(db.account.proxy_type, "tor")
                                .with(db.account.id, "=", mig_row[db.account.id])
                                .perform();
                        }
                    }
                }
                db.settings.upsert()
                    .value(db.settings.key, "tor_socks5_migration_done", true)
                    .value(db.settings.value, "true")
                    .perform();
                debug("TorManager: socks5→tor migration completed and flagged.");
            }

            if (is_enabled) {
                debug("TorManager: state is ENABLED. Starting Tor...");
                is_starting_up = true;
                // FORCE apply proxy settings on startup (true) because the port might have changed dynamically (e.g. 9155 -> 9156)
                start_tor.begin(true, (obj, res) => {
                    is_starting_up = false;
                });
            } else {
                // CRITICAL FIX: If state is OFF, strictly ensure no accounts are left in SOCKS5 mode.
                debug("TorManager: state is DISABLED. Ensuring clear-net (DB Cleanup)...");
                cleanup_lingering_proxies.begin();
            }
        }


        private async void cleanup_lingering_proxies() {
            // 1. Collect targets: only clear proxy_type="tor" (set by TorManager).
            //    User-configured "socks5" proxies (including those on localhost) are NEVER touched.
            var targets = new Gee.ArrayList<int>();
            
            foreach (var row in db.account.select()) {
                string ptype = row[db.account.proxy_type];
                if (ptype == "tor") {
                    targets.add(row[db.account.id]);
                }
            }

            // 2. Remediate targets
            foreach (int id_val in targets) {
                    debug("TorManager: cleanup_lingering_proxies - Found lingering Tor proxy on account ID %d. Remediating...", id_val);

                // Fix RAM / Active Connections (property setters persist to DB via on_update)
                bool found_in_ram = false;
                if (stream_interactor != null) {
                    var accounts = stream_interactor.get_accounts();
                    foreach (var account in accounts) {
                        if (account.id == id_val) {
                            debug("TorManager: Forcing RAM disconnect for %s", account.bare_jid.to_string());
                            account.proxy_type = "none";
                            account.proxy_host = "";
                            account.proxy_port = 0;
                            found_in_ram = true;
                            yield reconnect_account(account);
                        }
                    }
                }
                // Account not loaded in RAM (e.g. disabled) — update DB directly
                if (!found_in_ram) {
                    db.account.update()
                        .set(db.account.proxy_type, "none")
                        .set(db.account.proxy_host, "")
                        .set(db.account.proxy_port, 0)
                        .with(db.account.id, "=", id_val)
                        .perform();
                }
            }
        }
        
        private void on_process_exited(int status) {
            if (is_shutting_down) {
                 debug("TorManager: Process exited during application shutdown (status %d). Ignoring.", status);
                 return;
            }

            // If user already disabled Tor, don't retry — just clean up
            if (!is_enabled) {
                debug("TorManager: Tor exited (status %d) but is_enabled=false. No retry.", status);
                return;
            }

            if (retry_count < MAX_RETRIES) {
                retry_count++;
                warning("TorManager: Tor exited unexpectedly with status %d so we are trying to fix it. Attempt %d/%d. Cleaning state...", status, retry_count, MAX_RETRIES);
                
                // Attempt to clean state which might be corrupted ("Acting on config options left us in a broken state")
                controller.clean_state();
                
                // Restart
                start_tor.begin(true);
                return;
            }

            warning("TorManager: [CRITICAL] Tor exited with status %d. Retries exhausted. Initiating emergency proxy removal.", status);
            // Force disable, regardless of current state check, to ensure cleanup happens
            set_enabled.begin(false); 
        }
        
        public async void set_bridges(string bridges) {
            debug("TorManager: Updating bridges settings.");
            controller.bridge_lines = bridges;
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_bridges", true)
                    .value(db.settings.value, bridges)
                    .perform();
            
            // If running, restart to apply
            if (is_enabled && !is_transitioning) {
                is_transitioning = true;
                try {
                    yield stop_tor(false);
                    yield start_tor(true);
                } finally {
                    is_transitioning = false;
                }
            }
        }

        public async void update_use_bridges(bool use) {
            if (use_bridges == use) return;
            use_bridges = use;
            controller.use_bridges = use;
            
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_use_bridges", true)
                    .value(db.settings.value, use ? "true" : "false")
                    .perform();
            
            if (is_enabled && !is_transitioning) {
                is_transitioning = true;
                try {
                    yield stop_tor(false);
                    yield start_tor(true);
                } finally {
                    is_transitioning = false;
                }
            }
        }

        public async void update_firewall_ports(bool use) {
            if (force_firewall_ports == use) return;
            force_firewall_ports = use;
            controller.force_firewall_ports = use;
            
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_firewall_ports", true)
                    .value(db.settings.value, use ? "true" : "false")
                    .perform();

            if (is_enabled && !is_transitioning) {
                is_transitioning = true;
                try {
                    yield stop_tor(false);
                    yield start_tor(true);
                } finally {
                    is_transitioning = false;
                }
            }
        }

        public async void set_enabled(bool enabled) {
            // Always update desired state + DB immediately, even during transitions
            is_enabled = enabled;

            var val = enabled ? "true" : "false";
            db.settings.upsert()
                    .value(db.settings.key, "tor_manager_enabled", true)
                    .value(db.settings.value, val)
                    .perform();

            if (is_transitioning) {
                debug("TorManager: set_enabled(%s) during active transition.", enabled.to_string());
                if (!enabled) {
                    // Kill Tor process immediately — the running start_tor
                    // will notice is_enabled==false at its next yield and bail out
                    controller.stop();
                }
                return;
            }
            debug("TorManager: set_enabled(%s) called. Current state: %s", enabled.to_string(), is_enabled.to_string());
            is_transitioning = true;

            try {
                if (enabled) {
                    debug("TorManager: Starting Tor...");
                    yield start_tor(true);
                    // If user toggled OFF while we were starting, clean up now
                    if (!is_enabled) {
                        debug("TorManager: User disabled Tor during startup. Cleaning up.");
                        yield stop_tor(true);
                    }
                } else {
                    debug("TorManager: Stopping Tor and cleaning up...");
                    yield stop_tor(true);
                }
            } finally {
                is_transitioning = false;
            }
        }

        public async void start_tor(bool apply_proxy = false) {
            yield controller.start();

            // Bail out if Tor was disabled while we were starting (user toggled OFF mid-startup)
            if (!is_enabled || !controller.is_running) {
                debug("TorManager: Tor disabled or not running after start(). Skipping proxy application.");
                return;
            }

            // Persist SOCKS port so UI and other components can read it
            db.settings.upsert()
                .value(db.settings.key, "tor_socks_port", true)
                .value(db.settings.value, controller.socks_port.to_string())
                .perform();
            debug("TorManager: Stored tor_socks_port=%d in DB", controller.socks_port);

            if (apply_proxy) {
                // Wait for Tor to fully bootstrap before applying proxy settings.
                // Otherwise, XMPP connections attempt to use the SOCKS5 proxy before
                // Tor has built circuits, resulting in "connection refused" errors.
                bool bootstrapped = yield wait_for_bootstrap(60);

                // Re-check: user may have disabled Tor while we waited for bootstrap
                if (!is_enabled || !controller.is_running) {
                    debug("TorManager: Tor disabled or died during bootstrap wait. Skipping proxy application.");
                    return;
                }

                if (bootstrapped) {
                    debug("TorManager: Tor bootstrapped, applying proxy settings now.");
                    apply_proxy_to_accounts(true);
                } else {
                    warning("TorManager: Tor bootstrap timed out. Applying proxy anyway (will retry on connect).");
                    apply_proxy_to_accounts(true);
                }
            }
        }

        /**
         * Wait until the TorController emits bootstrap_status with percent >= 100,
         * or until timeout_seconds expires. Returns true if bootstrap completed.
         */
        private async bool wait_for_bootstrap(int timeout_seconds) {
            if (!controller.is_running) return false;

            bool completed = false;
            ulong handler_id = 0;
            uint timeout_id = 0;

            handler_id = controller.bootstrap_status.connect((percent, summary) => {
                if (percent >= 100) {
                    completed = true;
                    wait_for_bootstrap.callback();
                }
            });

            timeout_id = Timeout.add_seconds((uint) timeout_seconds, () => {
                timeout_id = 0;
                wait_for_bootstrap.callback();
                return Source.REMOVE;
            });

            yield;

            // Cleanup
            if (handler_id != 0) {
                SignalHandler.disconnect(controller, handler_id);
            }
            if (timeout_id != 0) {
                Source.remove(timeout_id);
            }

            return completed;
        }

        public async void stop_tor(bool remove_proxy = false) {
            retry_count = 0;  // Reset for next enable cycle

            if (remove_proxy) {
                // Disconnect streams FIRST while Tor tunnel is still alive,
                // so </stream:stream> can be sent through the SOCKS5 proxy.
                // Then clear DB/RAM proxy settings and reconnect without proxy.
                debug("TorManager: stop_tor — disconnecting streams before killing Tor.");
                yield cleanup_lingering_proxies();
            }

            // Kill Tor AFTER streams are cleanly disconnected
            controller.stop();
        }

        public void apply_proxy_to_accounts(bool enable_tor) {
            
            if (enable_tor) {
                var accounts = stream_interactor.get_accounts();
                debug("TorManager: ENABLE sequence - Found %d managed accounts. Applying Port: %d", accounts.size, controller.socks_port);
                foreach (var account in accounts) {
                    // Skip accounts with a real standalone SOCKS5 proxy
                    if (is_standalone_socks5(account)) {
                        debug("TorManager: Skipping %s — has standalone SOCKS5 proxy", account.bare_jid.to_string());
                        continue;
                    }

                    bool port_changed = (account.proxy_port != controller.socks_port);
                    
                    // Update RAM object (property setters persist to DB via on_update)
                    account.proxy_type = "tor";
                    account.proxy_host = "127.0.0.1";
                    account.proxy_port = controller.socks_port;
                    
                    // 3. Only reconnect if the account is already connected/connecting
                    //    (skip during startup — accounts will connect with proxy settings
                    //    that we already set via on_account_added)
                    var state = stream_interactor.connection_manager.get_state(account);
                    if (state == ConnectionManager.ConnectionState.CONNECTED ||
                        state == ConnectionManager.ConnectionState.CONNECTING) {
                        if (port_changed) {
                            debug("TorManager: Port changed for %s, reconnecting through 127.0.0.1:%d",
                                  account.bare_jid.to_string(), controller.socks_port);
                            reconnect_account.begin(account);
                        } else {
                            debug("TorManager: %s already configured for port %d, no reconnect needed",
                                  account.bare_jid.to_string(), controller.socks_port);
                        }
                    } else {
                        debug("TorManager: %s not connected yet (state: %s), proxy settings applied for next connect",
                              account.bare_jid.to_string(), state.to_string());
                    }
                }
            } else {
                // DISABLE sequence - use the robust cleanup logic we unified
                debug("TorManager: DISABLE sequence - invoking robust cleanup_lingering_proxies()");
                cleanup_lingering_proxies.begin();
            }
        }

        private async void reconnect_account(Account account) {
             // Force reconnect to ensure new proxy settings are picked up immediately.
             // ALWAYS disconnect first, even in DISCONNECTED state, to cancel any
             // pending connect_stream attempts that still use old proxy settings.
             var cm = stream_interactor.connection_manager;
             var state = cm.get_state(account);
             debug("TorManager: Reconnecting %s (Current State: %s)", account.bare_jid.to_string(), state.to_string());

             // Disconnect to cancel stale connection attempts and clear connection entry
             yield cm.disconnect_account(account);
             yield new Request(500).await();

             // Use connection_manager directly — DO NOT call stream_interactor.connect_account()
             // which fires account_added again and confuses OMEMO, presence, and other modules.
             debug("TorManager: Reconnecting account %s with current proxy settings...", account.bare_jid.to_string());
             cm.connect_account(account);
        }
        
        // Helper class for async wait
        private class Request : Object {
            private uint interval;
            public Request(uint interval) { this.interval = interval; }
            public async void await() {
                Timeout.add(interval, () => {
                    await.callback();
                    return false;
                });
                yield;
            }
        }
    }
}
