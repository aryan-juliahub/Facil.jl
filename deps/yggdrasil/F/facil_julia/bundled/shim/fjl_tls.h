#ifndef FJL_TLS_H
#define FJL_TLS_H

#include "fjl.h"
#include "fjl_http.h"

#include <fio_tls.h>

/* Error codes of the calls below; `err` receives OpenSSL's reason. */
#define FJL_TLS_OK 0
#define FJL_TLS_BAD_CERT 1     /* no certificate in the PEM text */
#define FJL_TLS_BAD_KEY 2      /* no key, or a wrong or missing password */
#define FJL_TLS_KEY_MISMATCH 3 /* the key does not belong to the certificate */
#define FJL_TLS_REJECTED 4     /* OpenSSL refused the setting */
#define FJL_TLS_BAD_CA 5       /* no certificate in the trust PEM */

/* A TLS object without certificates; the server that receives it owns it. */
fio_tls_s *fjl_tls_new(void);
void fjl_tls_free(fio_tls_s *tls);
/* min/max as TLS1_x_VERSION (0 for the default), ciphers for TLS 1.2 and
 * suites for TLS 1.3 (NULL for the default), flags FIO_TLS_*. */
int fjl_tls_configure(fio_tls_s *tls, int min_version, int max_version,
                      const char *ciphers, const char *suites, int flags);
/* Sets the certificate served for `name` ("" is the default one). Checks the
 * pair first, so a bad pair changes nothing. Safe while serving. */
int fjl_tls_set_cert(fio_tls_s *tls, const char *name, const char *cert,
                     size_t cert_len, const char *key, size_t key_len,
                     const char *password, char *err, size_t err_len);
/* Adds CA certificates that client certificates are verified against. */
int fjl_tls_trust(fio_tls_s *tls, const char *pem, size_t len, char *err,
                  size_t err_len);
/* The TLS object of a server, or NULL for plain HTTP. */
fio_tls_s *fjl_tls_of(fjl_server_s *srv);

#endif
