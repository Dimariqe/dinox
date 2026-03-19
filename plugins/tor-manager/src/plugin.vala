using Dino;
using GLib;
using Adw;

namespace Dino.Plugins.TorManager {

    public class Plugin : RootInterface, Object {
        private TorManager? tor_manager;
        private TorIndicator? indicator;

        public void registered(Dino.Application app) {
            tor_manager = new TorManager(app.stream_interactor, app.db);
            app.stream_interactor.add_module(tor_manager);
            
            // Initialize UI Indicator
            indicator = new TorIndicator(tor_manager);
            
            app.configure_preferences.connect(on_preferences_configure);
        }
        
        public void shutdown() {
            if (tor_manager != null) {
                // IMPORTANT: Tell TorManager we are shutting down so it doesn't trigger "process exited" signals that disable the setting
                tor_manager.prepare_shutdown();

                var loop = new MainLoop(MainContext.@default(), false);
                tor_manager.stop_tor.begin(false, (obj, res) => {
                    tor_manager.stop_tor.end(res);
                    if (loop.is_running()) loop.quit();
                });
                Timeout.add(3000, () => {
                    debug("TorManager plugin shutdown: timeout reached");
                    if (loop.is_running()) loop.quit();
                    return Source.REMOVE;
                });
                loop.run();

                tor_manager = null;
            }
            indicator = null;
        }

        public void rekey_database(string new_key) throws Error {
            // No own database
        }

        public void checkpoint_database() {
            // No own database
        }
        
        private void on_preferences_configure(Object object) {
             Adw.PreferencesDialog? dialog = object as Adw.PreferencesDialog;
             if (dialog != null && tor_manager != null) {
                var page = new TorSettingsPage(tor_manager);
                dialog.add(page);

                // Match the main dialog breakpoint: hide title at narrow width
                var bp = new Adw.Breakpoint(new Adw.BreakpointCondition.length(Adw.BreakpointConditionLengthType.MAX_WIDTH, 600, Adw.LengthUnit.PX));
                bp.apply.connect(() => {
                    page.title = "";
                });
                bp.unapply.connect(() => {
                    page.title = _("Tor");
                });
                dialog.add_breakpoint(bp);
             }
        }
    }
}
