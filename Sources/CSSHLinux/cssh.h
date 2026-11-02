#include "libssh/libssh.h"
#include "libssh/sftp.h"
#include "libssh/callbacks.h"
#define CURL_DISABLE_TYPECHECK
#include "curl/curl.h"
#include "openssl/ssl.h"
#include "openssl/x509v3.h"

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
