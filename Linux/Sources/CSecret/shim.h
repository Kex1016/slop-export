#ifndef SLOP_CSECRET_SHIM_H
#define SLOP_CSECRET_SHIM_H

#include <libsecret/secret.h>

// libsecret's store/lookup/clear calls are variadic, which Swift cannot call. These wrappers fix
// the attributes to the two slop-export uses, mirroring the macOS Keychain items: service
// ("slop-export.bridge" / "slop-export.icloud") and account (the user name).

static inline const SecretSchema *slop_secret_schema(void) {
    static const SecretSchema schema = {
        "io.github.kex1016.SlopExport.Password", SECRET_SCHEMA_NONE,
        {
            { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        },
        0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    };
    return &schema;
}

static inline gboolean slop_secret_store(const char *service, const char *account, const char *label,
                                         const char *password, GError **error) {
    return secret_password_store_sync(slop_secret_schema(), SECRET_COLLECTION_DEFAULT, label, password,
                                      NULL, error, "service", service, "account", account, NULL);
}

/// Returns NULL when there is no item (and *error stays NULL). Free with secret_password_free.
static inline gchar *slop_secret_lookup(const char *service, const char *account, GError **error) {
    return secret_password_lookup_sync(slop_secret_schema(), NULL, error,
                                       "service", service, "account", account, NULL);
}

static inline gboolean slop_secret_clear(const char *service, const char *account, GError **error) {
    return secret_password_clear_sync(slop_secret_schema(), NULL, error,
                                      "service", service, "account", account, NULL);
}

#endif
