// Signs one Mach-O file (a dylib) in place on the device, using zsign.
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Signs `machoPath` in place with the private key at `keyPath` (PEM, DER or
/// PKCS#12; `password` may be NULL). The certificate is `certPath` (PEM or DER)
/// if given and it matches the key, else the one in the provisioning profile at
/// `provPath` that matches it. The profile also supplies the team ID. `identifier` becomes the signature's
/// identifier (NULL = the file name). The zsign log is appended to `logBuf`.
/// Returns 0 on success, non-zero on failure.
int sst_sign_macho(const char *machoPath,
                   const char *keyPath,
                   const char *certPath,
                   const char *password,
                   const char *provPath,
                   const char *identifier,
                   char *logBuf,
                   size_t logLen);

#ifdef __cplusplus
}
#endif
