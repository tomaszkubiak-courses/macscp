#include "libssh/libssh.h"
#include "libssh/sftp.h"
#include "libssh/callbacks.h"
#define CURL_DISABLE_TYPECHECK
#include "curl/curl.h"
#include "openssl/ssl.h"
#include "openssl/x509v3.h"

static const long CSSH_FTP_SINGLECWD = CURLFTPMETHOD_SINGLECWD;
static const long CSSH_USESSL_ALL = CURLUSESSL_ALL;

static inline CURLcode cssh_curl_global_init(void) { return curl_global_init(CURL_GLOBAL_ALL); }
static inline CURLcode cssh_curl_long(CURL *c, CURLoption o, long v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode cssh_curl_offset(CURL *c, CURLoption o, curl_off_t v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode cssh_curl_string(CURL *c, CURLoption o, const char *v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode cssh_curl_pointer(CURL *c, CURLoption o, void *v) { return curl_easy_setopt(c, o, v); }
static inline CURLcode cssh_curl_write(CURL *c, CURLoption o, curl_write_callback f) { return curl_easy_setopt(c, o, f); }
static inline CURLcode cssh_curl_read(CURL *c, curl_read_callback f) { return curl_easy_setopt(c, CURLOPT_READFUNCTION, f); }
static inline CURLcode cssh_curl_xferinfo(CURL *c, curl_xferinfo_callback f) { return curl_easy_setopt(c, CURLOPT_XFERINFOFUNCTION, f); }
static inline CURLcode cssh_curl_ssl_ctx(CURL *c, curl_ssl_ctx_callback f) { return curl_easy_setopt(c, CURLOPT_SSL_CTX_FUNCTION, f); }
static inline long cssh_curl_info_long(CURL *c, CURLINFO i) { long v = 0; curl_easy_getinfo(c, i, &v); return v; }
static inline const char *cssh_curl_info_string(CURL *c, CURLINFO i) { const char *v = NULL; curl_easy_getinfo(c, i, &v); return v; }

#include "openssl/evp.h"
#include "openssl/kdf.h"
#include "openssl/core_names.h"
#include "openssl/hmac.h"

static inline int cssh_argon2(const char *alg, const void *pass, size_t passlen, const void *salt, size_t saltlen,
                              uint32_t memory, uint32_t passes, uint32_t lanes, unsigned char *out, size_t outlen) {
    EVP_KDF *kdf = EVP_KDF_fetch(NULL, alg, NULL);
    if (kdf == NULL) return -1;
    EVP_KDF_CTX *ctx = EVP_KDF_CTX_new(kdf);
    EVP_KDF_free(kdf);
    if (ctx == NULL) return -1;
    uint32_t threads = 1;
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_octet_string("pass", (void *)pass, passlen),
        OSSL_PARAM_construct_octet_string("salt", (void *)salt, saltlen),
        OSSL_PARAM_construct_uint32("iter", &passes),
        OSSL_PARAM_construct_uint32("memcost", &memory),
        OSSL_PARAM_construct_uint32("lanes", &lanes),
        OSSL_PARAM_construct_uint32("threads", &threads),
        OSSL_PARAM_construct_end()
    };
    int rc = EVP_KDF_derive(ctx, out, outlen, params);
    EVP_KDF_CTX_free(ctx);
    return rc == 1 ? 0 : -2;
}
