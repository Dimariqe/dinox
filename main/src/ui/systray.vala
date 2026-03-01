/*
 * Copyright (C) 2025 Ralf Peter <dinox@handwerker.jetzt>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Linux Systray - StatusNotifierItem (SNI) with libdbusmenu.
 * Works natively on KDE, Cinnamon, MATE, XFCE.
 * On GNOME, requires AppIndicator/KStatusNotifierItem extension.
 * Falls back to GApplication.hold() if no SNI watcher is available.
 *
 * IconPixmap support: Quickshell reads IconPixmap as a(iiay) directly
 * (no variant wrapper). When pixmaps are loaded we clear IconName so
 * Quickshell's QIcon::fromTheme path is bypassed entirely and the
 * inline ARGB32 data is used instead.
 */

using Gtk;
using Gee;
using Dbusmenu;
using GLib;

namespace Dino.Ui {

// One SNI pixmap entry.  D-Bus signature of the array: a(iiay)
public struct SniPixmap {
    public int32  width;
    public int32  height;
    public uint8[] data;
}

[DBus (name = "org.kde.StatusNotifierItem")]
public class StatusNotifierItem : Object {

    // When icon_pixmap is populated we set icon_name to "" so that
    // Quickshell (and other Qt trays) skip QIcon::fromTheme() and use
    // the inline pixel data instead.
    public string status       { get; set; default = "Active"; }
    public string icon_name    { get; set; default = "im.github.rallep71.DinoX"; }
    public string title        { get; set; default = "DinoX"; }
    public string category     { get; set; default = "Communications"; }
    public string id           { get; set; default = "dinox"; }
    public bool   item_is_menu { get; set; default = false; }

    // Parent directory that contains the "hicolor" sub-tree.
    // e.g. "/usr/share/icons"  (not ".../hicolor" itself).
    public string icon_theme_path { get; set; default = ""; }

    public ObjectPath menu {
        owned get { return new ObjectPath("/MenuBar"); }
    }

    // Exposed as a(iiay) — the exact type Quickshell deserialises with
    // qDBusRegisterMetaType<DBusSniIconPixmapList>().
    // We use GLib.Variant with an explicit [DBus (signature)] annotation
    // so GDBus emits the bare a(iiay) wire type without an extra
    // variant wrapper (which would happen with an untyped Variant property).
    private GLib.Variant _icon_pixmap = new GLib.Variant("a(iiay)", null);

    [DBus (signature = "a(iiay)")]
    public GLib.Variant icon_pixmap {
        owned get { return _icon_pixmap; }
    }

    [DBus (name = "NewIcon")]
    public signal void new_icon();

    [DBus (name = "NewStatus")]
    public signal void new_status(string status);

    public signal void activate          (int x, int y);
    public signal void secondary_activate(int x, int y);

    [DBus (name = "Activate")]
    public void dbus_activate(int x, int y) throws Error {
        activate(x, y);
    }

    [DBus (name = "SecondaryActivate")]
    public void dbus_secondary_activate(int x, int y) throws Error {
        secondary_activate(x, y);
    }

    [DBus (name = "ContextMenu")]
    public void context_menu(int x, int y) throws Error {
        debug("Systray: ContextMenu called at (%d, %d)", x, y);
    }

    [DBus (name = "Scroll")]
    public void scroll(int delta, string orientation) throws Error {
    }

    public void update_icon(string icon) throws Error {
        icon_name = icon;
        new_icon();
    }

    public void update_status(string new_status_value) throws Error {
        status = new_status_value;
        new_status(new_status_value);
    }

    // ----------------------------------------------------------------
    // IconPixmap loading
    // ----------------------------------------------------------------

    // Load PNG icons from hicolor_dir (e.g. /usr/share/icons/hicolor)
    // and populate the icon_pixmap property.
    // On success icon_name is cleared so Qt-based hosts use the pixmaps.
    public void load_icon_pixmaps(string hicolor_dir) {
        int[] sizes = { 256, 128, 48, 32, 16 };
        string icon_id = "im.github.rallep71.DinoX";

        var builder = new GLib.VariantBuilder(new GLib.VariantType("a(iiay)"));
        int count = 0;

        foreach (int sz in sizes) {
            string path = Path.build_filename(
                hicolor_dir, "%dx%d".printf(sz, sz), "apps", icon_id + ".png");

            uint8[]? argb = load_png_as_argb32(path, sz);
            if (argb == null) continue;

            // Build the byte array child
            var bytes_builder = new GLib.VariantBuilder(new GLib.VariantType("ay"));
            foreach (uint8 b in argb) {
                bytes_builder.add("y", b);
            }

            builder.add("(ii@ay)", (int32) sz, (int32) sz, bytes_builder.end());
            count++;
            debug("Systray: loaded IconPixmap %dx%d from %s", sz, sz, path);
        }

        if (count > 0) {
            _icon_pixmap = builder.end();
            // Clear IconName so Qt-based hosts skip QIcon::fromTheme() and
            // use our inline pixel data instead.
            icon_name = "";
            debug("Systray: IconPixmap populated (%d sizes), IconName cleared", count);
        } else {
            debug("Systray: no PNG icons found for IconPixmap, keeping IconName");
        }
    }

    // Load a PNG with GdkPixbuf and convert to ARGB32 big-endian bytes.
    private uint8[]? load_png_as_argb32(string path, int expected_size) {
        if (!FileUtils.test(path, FileTest.IS_REGULAR)) return null;

        try {
            var pb = new Gdk.Pixbuf.from_file(path);
            if (pb == null) return null;

            if (!pb.get_has_alpha()) {
                pb = pb.add_alpha(false, 0, 0, 0);
                if (pb == null) return null;
            }
            if (pb.get_width() != expected_size || pb.get_height() != expected_size) {
                pb = pb.scale_simple(expected_size, expected_size, Gdk.InterpType.BILINEAR);
                if (pb == null) return null;
            }

            int width     = pb.get_width();
            int height    = pb.get_height();
            int rowstride = pb.get_rowstride();
            unowned uint8[] pixels = pb.get_pixels();

            // GdkPixbuf RGBA  →  SNI ARGB32 big-endian (bytes: A R G B)
            uint8[] argb = new uint8[width * height * 4];
            int dst = 0;
            for (int y = 0; y < height; y++) {
                int row = y * rowstride;
                for (int x = 0; x < width; x++) {
                    int s = row + x * 4;
                    argb[dst    ] = pixels[s + 3]; // A
                    argb[dst + 1] = pixels[s    ]; // R
                    argb[dst + 2] = pixels[s + 1]; // G
                    argb[dst + 3] = pixels[s + 2]; // B
                    dst += 4;
                }
            }
            return argb;
        } catch (Error e) {
            debug("Systray: failed to load %s: %s", path, e.message);
            return null;
        }
    }
}

// ====================================================================

public class SystrayManager : Object {

    private unowned Application application;
    public MainWindow? window;
    private StatusNotifierItem? status_notifier;
    private Dbusmenu.Server? menu_server;
    private uint dbus_id = 0;
    private DBusConnection? connection;
    private Dbusmenu.Menuitem[] status_items;
    private ulong status_changed_id = 0;
    private uint watcher_id = 0;
    private bool sni_registered = false;

    public bool is_hidden = false;

    public SystrayManager(Application application) {
        this.application = application;
        initialize_dbus.begin();
    }

    public void set_window(MainWindow window) {
        this.window = window;

        window.close_request.connect(() => {
            if (Dino.Application.get_default().settings.keep_background) {
                hide_window();
                return true;
            } else {
                quit_application();
                return true;
            }
        });
    }

    public void quit_application() {
        debug("Systray: quit_application() called");

        if (window != null) window.hide();

        cleanup();

        debug("Systray: Disconnecting all accounts...");
        application.stream_interactor.connection_manager.disconnect_all();

        finalize_quit();
    }

    private void finalize_quit() {
        debug("Systray: Calling application.quit()");
        application.quit();

        debug("Systray: Force exit - Process.exit(0)");
        Process.exit(0);
    }

    private async void initialize_dbus() {
        try {
            var conn = yield Bus.get(BusType.SESSION);
            if (disposed) return;
            connection = conn;

            status_notifier = new StatusNotifierItem();
            status_notifier.activate.connect(on_activate);
            status_notifier.secondary_activate.connect(on_secondary_activate);

            // Resolve the hicolor icon directory and set IconThemePath.
            //
            // Priority:
            //   1. $APPDIR/usr/share/icons/hicolor  — AppImage runtime
            //   2. $XDG_DATA_DIRS entries            — normal install / Flatpak
            //   3. $XDG_DATA_HOME                   — user-local install
            //   4. /usr/share/icons/hicolor          — hard fallback
            //
            // icon_theme_path is the *parent* of "hicolor"
            // (i.e. /usr/share/icons), matching the SNI spec.
            string hicolor_dir = resolve_hicolor_dir();
            status_notifier.icon_theme_path = Path.get_dirname(hicolor_dir);
            debug("Systray: icon_theme_path=%s  hicolor_dir=%s",
                  status_notifier.icon_theme_path, hicolor_dir);

            status_notifier.load_icon_pixmaps(hicolor_dir);

            // Dbusmenu
            menu_server = new Dbusmenu.Server("/MenuBar");

            var root = new Dbusmenu.Menuitem();
            root.property_set(Dbusmenu.MENUITEM_PROP_CHILD_DISPLAY, "submenu");
            menu_server.set_root(root);

            string[] statuses = {"online", "away", "dnd", "xa"};
            string[] labels   = {_("Online"), _("Away"), _("Busy"), _("Not Available")};
            status_items = new Dbusmenu.Menuitem[statuses.length];

            for (int i = 0; i < statuses.length; i++) {
                var s    = statuses[i];
                var item = new Dbusmenu.Menuitem();
                item.property_set     (Dbusmenu.MENUITEM_PROP_LABEL,   labels[i]);
                item.property_set_bool(Dbusmenu.MENUITEM_PROP_ENABLED, true);
                item.property_set_bool(Dbusmenu.MENUITEM_PROP_VISIBLE, true);
                item.item_activated.connect((timestamp) => {
                    application.activate_action("set-status", new Variant.string(s));
                });
                status_items[i] = item;
                root.child_append(item);
            }

            var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            status_changed_id = pm.status_changed.connect((show, msg) => {
                update_status_items(show);
            });
            update_status_items(pm.get_current_show());

            var item_sep = new Dbusmenu.Menuitem();
            item_sep.property_set     (Dbusmenu.MENUITEM_PROP_TYPE,    Dbusmenu.CLIENT_TYPES_SEPARATOR);
            item_sep.property_set_bool(Dbusmenu.MENUITEM_PROP_VISIBLE, true);
            root.child_append(item_sep);

            var item_quit = new Dbusmenu.Menuitem();
            item_quit.property_set     (Dbusmenu.MENUITEM_PROP_LABEL,     _("Quit"));
            item_quit.property_set_bool(Dbusmenu.MENUITEM_PROP_ENABLED,   true);
            item_quit.property_set_bool(Dbusmenu.MENUITEM_PROP_VISIBLE,   true);
            item_quit.property_set     (Dbusmenu.MENUITEM_PROP_ICON_NAME, "application-exit-symbolic");
            item_quit.item_activated.connect((timestamp) => {
                Timeout.add(50, () => { quit_application(); return false; });
            });
            root.child_append(item_quit);

            debug("Systray: Dbusmenu.Server initialized on /MenuBar");

            dbus_id = connection.register_object("/StatusNotifierItem", status_notifier);
            debug("Systray: StatusNotifierItem registered on D-Bus");

            start_watching();

        } catch (Error e) {
            warning("Systray: Failed to initialize D-Bus: %s", e.message);
            application.hold();
            debug("Systray: Using GApplication.hold() fallback for background mode");
        }
    }

    // ------------------------------------------------------------------
    // Icon directory resolution
    // ------------------------------------------------------------------

    // Returns the full path to the hicolor directory, e.g.
    // /usr/share/icons/hicolor
    private string resolve_hicolor_dir() {
        string icon_id = "im.github.rallep71.DinoX";

        // 1. AppImage
        string? appdir = Environment.get_variable("APPDIR");
        if (appdir != null) {
            string c = Path.build_filename(appdir, "usr", "share", "icons", "hicolor");
            if (icon_exists_in_hicolor(c, icon_id)) {
                debug("Systray: hicolor via APPDIR: %s", c);
                return c;
            }
        }

        // 2. XDG_DATA_DIRS
        string? xdg_dirs = Environment.get_variable("XDG_DATA_DIRS");
        if (xdg_dirs != null) {
            foreach (string d in xdg_dirs.split(":")) {
                string c = Path.build_filename(d, "icons", "hicolor");
                if (icon_exists_in_hicolor(c, icon_id)) {
                    debug("Systray: hicolor via XDG_DATA_DIRS: %s", c);
                    return c;
                }
            }
        }

        // 3. XDG_DATA_HOME
        string xdg_home = Environment.get_variable("XDG_DATA_HOME")
            ?? Path.build_filename(Environment.get_home_dir(), ".local", "share");
        {
            string c = Path.build_filename(xdg_home, "icons", "hicolor");
            if (icon_exists_in_hicolor(c, icon_id)) {
                debug("Systray: hicolor via XDG_DATA_HOME: %s", c);
                return c;
            }
        }

        // 4. Hard fallback
        string fb = "/usr/share/icons/hicolor";
        debug("Systray: hicolor fallback: %s", fb);
        return fb;
    }

    private bool icon_exists_in_hicolor(string hicolor_dir, string icon_id) {
        foreach (int sz in new int[]{ 48, 32, 256 }) {
            string p = Path.build_filename(
                hicolor_dir, "%dx%d".printf(sz, sz), "apps", icon_id + ".png");
            if (FileUtils.test(p, FileTest.IS_REGULAR)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // SNI watcher registration
    // ------------------------------------------------------------------

    private void start_watching() {
        watcher_id = Bus.watch_name(BusType.SESSION, "org.kde.StatusNotifierWatcher",
            BusNameWatcherFlags.NONE,
            (conn, name, owner) => {
                debug("Systray: StatusNotifierWatcher appeared (%s)", owner);
                register_with_watcher.begin();
            },
            (conn, name) => {
                debug("Systray: StatusNotifierWatcher vanished");
                if (!sni_registered) {
                    application.hold();
                    debug("Systray: no SNI watcher, using GApplication.hold() fallback");
                }
            }
        );
    }

    private async void register_with_watcher() {
        if (disposed || connection == null) return;

        string[] watchers = {
            "org.kde.StatusNotifierWatcher",
            "org.x.StatusNotifierWatcher"
        };

        bool registered = false;
        foreach (string watcher_name in watchers) {
            try {
                if (disposed || connection == null) return;
                StatusNotifierWatcher watcher = yield connection.get_proxy(
                    watcher_name, "/StatusNotifierWatcher", DBusProxyFlags.NONE);

                if (disposed || connection == null) return;
                yield watcher.register_status_notifier_item(connection.unique_name);

                debug("Systray: registered with %s as %s",
                      watcher_name, connection.unique_name);
                registered = true;
                sni_registered = true;
                break;

            } catch (Error e) {
                continue;
            }
        }

        if (!registered) {
            warning("Systray: no StatusNotifierWatcher — tray icon will not be visible");
            application.hold();
            debug("Systray: using GApplication.hold() fallback");
        }
    }

    // ------------------------------------------------------------------
    // Window management
    // ------------------------------------------------------------------

    private void on_activate          (int x, int y) { toggle_window_visibility(); }
    private void on_secondary_activate(int x, int y) { toggle_window_visibility(); }

    public void toggle_window_visibility() {
        if (window == null) return;
        if (is_hidden || !window.is_visible()) show_window();
        else                                    hide_window();
    }

    private void show_window() {
        if (window == null) return;
        window.present();
        window.set_visible(true);
        is_hidden = false;
    }

    private void hide_window() {
        if (window == null) return;
        window.set_visible(false);
        is_hidden = true;
    }

    // ------------------------------------------------------------------
    // Status menu helpers
    // ------------------------------------------------------------------

    private void update_status_items(string current_status) {
        if (status_items == null) return;

        string[] statuses      = {"online",  "away",  "dnd",  "xa"};
        string[] labels        = {_("Online"), _("Away"), _("Busy"), _("Not Available")};
        string[] active_emojis = {"🟢", "🟠", "🔴", "⭕"};
        string   inactive      = "⚪";

        for (int i = 0; i < statuses.length; i++) {
            if (status_items[i] == null) continue;
            string emoji = (statuses[i] == current_status) ? active_emojis[i] : inactive;
            status_items[i].property_set(Dbusmenu.MENUITEM_PROP_LABEL, emoji + "  " + labels[i]);
        }
    }

    // ------------------------------------------------------------------
    // Cleanup
    // ------------------------------------------------------------------

    private bool disposed = false;

    public void cleanup() {
        if (disposed) return;
        disposed = true;

        if (watcher_id != 0) {
            Bus.unwatch_name(watcher_id);
            watcher_id = 0;
        }

        if (status_changed_id != 0) {
            var pm = application.stream_interactor.get_module<PresenceManager>(PresenceManager.IDENTITY);
            SignalHandler.disconnect(pm, status_changed_id);
            status_changed_id = 0;
        }

        if (connection != null && !connection.is_closed() && dbus_id != 0) {
            connection.unregister_object(dbus_id);
            dbus_id = 0;
        }

        status_items   = null;
        menu_server    = null;
        status_notifier = null;
        connection     = null;
    }

    ~SystrayManager() { cleanup(); }
}

[DBus (name = "org.kde.StatusNotifierWatcher")]
interface StatusNotifierWatcher : Object {
    public abstract async void register_status_notifier_item(string service) throws Error;
}

}
