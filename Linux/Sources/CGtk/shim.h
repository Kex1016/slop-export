#ifndef SLOP_CGTK_SHIM_H
#define SLOP_CGTK_SHIM_H

#include <gtk/gtk.h>
#include <glib-unix.h>

// g_signal_connect is a macro; Swift needs a function.
static inline gulong slop_signal_connect(gpointer instance, const char *signal, GCallback handler,
                                         gpointer data, GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, data, destroy, (GConnectFlags)0);
}

// libdispatch's hook for a foreign run loop: the file descriptor that becomes readable when the
// main queue has work, and the call that drains it. CoreFoundation's run loop uses the same two
// on Linux. The GTK app watches the descriptor from the GLib main loop, so Swift's main actor
// runs on GTK's thread and wakes only when there is work.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

#endif
