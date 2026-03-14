/*
 * Win32 Shell_NotifyIcon systray helper for DinoX.
 *
 * Creates a hidden message-only window to receive WM_APP tray callbacks,
 * uses Shell_NotifyIconW for the notification-area icon, and
 * CreatePopupMenu / TrackPopupMenu for the right-click context menu.
 *
 * All Win32 calls use the wide (W) variants.  UTF-8 ↔ UTF-16 conversion
 * is done via GLib's g_utf8_to_utf16().
 *
 * Thread safety: all functions must be called from the GTK main thread
 * (which owns the GDK Win32 display and message pump).
 */

#include "systray_win32.h"

#ifdef _WIN32

#include <windows.h>
#include <shellapi.h>

#define WM_TRAYICON  (WM_APP + 1)
#define MAX_MENU_ITEMS 32

/* ---- state ---- */
static HWND            msg_hwnd   = NULL;
static NOTIFYICONDATAW nid        = {0};
static HMENU           popup_menu = NULL;
static gboolean        initialised = FALSE;

static SystrayWin32Callback user_callback = NULL;
static gpointer             user_data_ptr = NULL;

/* ---- forward ---- */
static LRESULT CALLBACK wnd_proc (HWND, UINT, WPARAM, LPARAM);

/* ---- helpers ---- */
static wchar_t *
utf8_to_wchar (const gchar *s)
{
    if (s == NULL) return NULL;
    glong len = 0;
    gunichar2 *w = g_utf8_to_utf16 (s, -1, NULL, &len, NULL);
    return (wchar_t *) w;
}

/* ---- public API ---- */

gboolean
systray_win32_init (const gchar          *tooltip_utf8,
                    int                   icon_resource_id,
                    SystrayWin32Callback  callback,
                    gpointer              user_data)
{
    if (initialised) return TRUE;

    user_callback  = callback;
    user_data_ptr  = user_data;

    /* Register a minimal window class for the message-only window. */
    WNDCLASSEXW wc = {0};
    wc.cbSize        = sizeof (wc);
    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance      = GetModuleHandleW (NULL);
    wc.lpszClassName  = L"DinoXSystrayMsg";
    RegisterClassExW (&wc);

    /* Message-only window (HWND_MESSAGE parent → invisible, no taskbar entry). */
    msg_hwnd = CreateWindowExW (0, L"DinoXSystrayMsg", L"DinoX Tray",
                                0, 0, 0, 0, 0, HWND_MESSAGE, NULL,
                                GetModuleHandleW (NULL), NULL);
    if (msg_hwnd == NULL) return FALSE;

    /* Load icon from the .exe resource (IDI_ICON1 = 1 in dinox.rc). */
    HICON icon = LoadIconW (GetModuleHandleW (NULL),
                            MAKEINTRESOURCEW (icon_resource_id));
    if (icon == NULL) {
        /* Fallback to the default application icon (IDI_APPLICATION = 32512). */
        icon = LoadIconW (NULL, MAKEINTRESOURCEW (32512));
    }

    /* Set up NOTIFYICONDATAW. */
    memset (&nid, 0, sizeof (nid));
    nid.cbSize           = sizeof (nid);
    nid.hWnd             = msg_hwnd;
    nid.uID              = 1;
    nid.uFlags           = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = WM_TRAYICON;
    nid.hIcon            = icon;

    if (tooltip_utf8) {
        wchar_t *tip = utf8_to_wchar (tooltip_utf8);
        if (tip) {
            wcsncpy (nid.szTip, tip, G_N_ELEMENTS (nid.szTip) - 1);
            g_free (tip);
        }
    }

    Shell_NotifyIconW (NIM_ADD, &nid);
    initialised = TRUE;

    /* Create an empty popup menu (will be filled by set_menu). */
    popup_menu = CreatePopupMenu ();

    return TRUE;
}

void
systray_win32_set_menu (const gchar **labels, guint32 checked_mask)
{
    if (popup_menu == NULL) return;

    /* Clear existing items. */
    while (GetMenuItemCount (popup_menu) > 0)
        RemoveMenu (popup_menu, 0, MF_BYPOSITION);

    if (labels == NULL) return;

    for (int i = 0; labels[i] != (const gchar *) -1 && i < MAX_MENU_ITEMS; i++) {
        if (labels[i] == NULL) {
            AppendMenuW (popup_menu, MF_SEPARATOR, 0, NULL);
        } else {
            wchar_t *w = utf8_to_wchar (labels[i]);
            UINT flags = MF_STRING;
            if (checked_mask & (1u << i))
                flags |= MF_CHECKED;
            AppendMenuW (popup_menu, flags, (UINT_PTR)(i + 1), w);
            g_free (w);
        }
    }
}

void
systray_win32_set_tooltip (const gchar *tooltip_utf8)
{
    if (!initialised) return;

    memset (nid.szTip, 0, sizeof (nid.szTip));
    if (tooltip_utf8) {
        wchar_t *tip = utf8_to_wchar (tooltip_utf8);
        if (tip) {
            wcsncpy (nid.szTip, tip, G_N_ELEMENTS (nid.szTip) - 1);
            g_free (tip);
        }
    }
    nid.uFlags = NIF_TIP;
    Shell_NotifyIconW (NIM_MODIFY, &nid);
}

void
systray_win32_cleanup (void)
{
    if (!initialised) return;
    initialised = FALSE;

    Shell_NotifyIconW (NIM_DELETE, &nid);

    if (popup_menu) {
        DestroyMenu (popup_menu);
        popup_menu = NULL;
    }
    if (msg_hwnd) {
        DestroyWindow (msg_hwnd);
        msg_hwnd = NULL;
    }

    user_callback  = NULL;
    user_data_ptr  = NULL;
}

/* ---- Window procedure ---- */

static LRESULT CALLBACK
wnd_proc (HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_TRAYICON) {
        switch (LOWORD (lParam)) {
        case WM_LBUTTONUP:
            /* Left-click: toggle window visibility. */
            if (user_callback)
                user_callback (-1, user_data_ptr);
            break;

        case WM_RBUTTONUP: {
            /* Right-click: show context menu at cursor position. */
            if (popup_menu == NULL) break;

            POINT pt;
            GetCursorPos (&pt);

            /* Required so TrackPopupMenu works properly when DinoX
             * is not the foreground window. */
            SetForegroundWindow (hwnd);

            int cmd = (int) TrackPopupMenu (popup_menu,
                TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                pt.x, pt.y, 0, hwnd, NULL);

            PostMessage (hwnd, WM_NULL, 0, 0);   /* dismiss cleanly */

            if (cmd > 0 && user_callback)
                user_callback (cmd - 1, user_data_ptr);
            break;
        }
        default:
            break;
        }
        return 0;
    }

    return DefWindowProcW (hwnd, msg, wParam, lParam);
}

#else /* !_WIN32 — stubs for Linux builds (never called) */

gboolean systray_win32_init (const gchar *t, int r, SystrayWin32Callback c, gpointer u) { return FALSE; }
void systray_win32_set_menu (const gchar **l, guint32 m) {}
void systray_win32_set_tooltip (const gchar *t) {}
void systray_win32_cleanup (void) {}

#endif
