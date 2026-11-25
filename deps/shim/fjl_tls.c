#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "fjl_tls.h"

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <stdio.h>
#include <string.h>

static int fail(int code, char *err, size_t err_len) {
  unsigned long e = ERR_peek_last_error();
  if (err && err_len) {
    err[0] = 0;
    if (e)
      ERR_error_string_n(e, err, err_len);
  }
  ERR_clear_error();
  return code;
}

static int password_cb(char *buf, int size, int rwflag, void *u) {
  const char *p = u;
  if (!p || !size)
    return 0;
  int len = (int)strlen(p);
  if (len >= size)
    len = size - 1;
  memcpy(buf, p, len);
  buf[len] = 0;
  return len;
  (void)rwflag;
}

fio_tls_s *fjl_tls_new(void) { return fio_tls_new(NULL, NULL, NULL, NULL); }

void fjl_tls_free(fio_tls_s *tls) {
  if (tls)
    fio_tls_destroy(tls);
}

int fjl_tls_configure(fio_tls_s *tls, int min_version, int max_version,
                      const char *ciphers, const char *suites, int flags) {
  ERR_clear_error();
  SSL_CTX *probe = SSL_CTX_new(TLS_method());
  int ok = probe &&
           (!min_version || SSL_CTX_set_min_proto_version(probe, min_version)) &&
           (!max_version || SSL_CTX_set_max_proto_version(probe, max_version)) &&
           (!ciphers || SSL_CTX_set_cipher_list(probe, ciphers) == 1) &&
           (!suites || SSL_CTX_set_ciphersuites(probe, suites) == 1);
  SSL_CTX_free(probe);
  ERR_clear_error();
  if (!ok)
    return FJL_TLS_REJECTED;
  return fio_tls_configure(tls, min_version, max_version, ciphers, suites,
                           flags)
             ? FJL_TLS_REJECTED
             : FJL_TLS_OK;
}

int fjl_tls_set_cert(fio_tls_s *tls, const char *name, const char *cert,
                     size_t cert_len, const char *key, size_t key_len,
                     const char *password, char *err, size_t err_len) {
  ERR_clear_error();
  BIO *b = BIO_new_mem_buf(cert, (int)cert_len);
  X509 *x = b ? PEM_read_bio_X509(b, NULL, password_cb, NULL) : NULL;
  BIO_free(b);
  if (!x)
    return fail(FJL_TLS_BAD_CERT, err, err_len);
  b = BIO_new_mem_buf(key, (int)key_len);
  EVP_PKEY *k = b ? PEM_read_bio_PrivateKey(b, NULL, password_cb,
                                            (void *)password)
                  : NULL;
  BIO_free(b);
  if (!k) {
    X509_free(x);
    return fail(FJL_TLS_BAD_KEY, err, err_len);
  }
  int match = X509_check_private_key(x, k) == 1;
  X509_free(x);
  EVP_PKEY_free(k);
  if (!match)
    return fail(FJL_TLS_KEY_MISMATCH, err, err_len);
  if (fio_tls_cert_set_pem(tls, name, cert, cert_len, key, key_len,
                           password))
    return fail(FJL_TLS_REJECTED, err, err_len);
  ERR_clear_error();
  return FJL_TLS_OK;
}

int fjl_tls_trust(fio_tls_s *tls, const char *pem, size_t len, char *err,
                  size_t err_len) {
  ERR_clear_error();
  BIO *b = BIO_new_mem_buf(pem, (int)len);
  X509 *x = b ? PEM_read_bio_X509(b, NULL, password_cb, NULL) : NULL;
  BIO_free(b);
  if (!x)
    return fail(FJL_TLS_BAD_CA, err, err_len);
  X509_free(x);
  if (fio_tls_trust_pem(tls, pem, len))
    return fail(FJL_TLS_REJECTED, err, err_len);
  return FJL_TLS_OK;
}

fio_tls_s *fjl_tls_of(fjl_server_s *srv) {
  return srv ? fjl_http_settings(srv)->tls : NULL;
}

/* TLS connections are flushed on the reactor only; writes from other
 * threads leave the flush to it. */
static int off_reactor(void) { return !fjl_on_reactor(); }

__attribute__((constructor)) static void fjl_tls_init(void) {
  fio_flush_elsewhere = off_reactor;
  fio_flush_wake = fjl_wake;
}
