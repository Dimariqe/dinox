/*
 * Win32 Shell_NotifyIcon systray helper for DinoX.
 * Provides a notification-area icon with left-click toggle and right-click popup menu.
 */

#ifndef SYSTRAY_WIN32_H
#define SYSTRAY_WIN32_H

#include <glib.h>

/* Callback: user clicked a menu item (menu_id = 0..N-1 items, or -1 for left-click) */
typedef void (*SystrayWin32Callback)(int menu_id, gpointer user_data);

/* Initialise the tray icon.  tooltip_utf8 is shown on hover.
 * icon_resource_id: resource index in the .exe (1 = IDI_ICON1 from dinox.rc)
 * Returns TRUE on success. */
gboolean systray_win32_init   (const gchar          *tooltip_utf8,
                                int                   icon_resource_id,
                                SystrayWin32Callback  callback,
                                gpointer              user_data);

/* Replace the entire popup menu.  labels is a NULL-terminated array of
 * UTF-8 strings.  A NULL entry inserts a separator.
 * checked_mask: bitmask of items that should show a checkmark (bullet). */
void     systray_win32_set_menu (const gchar **labels, guint32 checked_mask);

/* Update the hover tooltip. */
void     systray_win32_set_tooltip (const gchar *tooltip_utf8);

/* Remove tray icon and clean up. */
void     systray_win32_cleanup (void);

#endif /* SYSTRAY_WIN32_H */
