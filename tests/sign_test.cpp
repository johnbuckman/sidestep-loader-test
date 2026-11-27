// Linux/macOS check of the on-device signer: signs a dylib, then has zsign verify it.
// Usage: sign_test <dylib> <key> <embedded.mobileprovision> [cert]
#include "sst_signer.h"
#include "common.h"
#include "macho.h"
#include <cstdio>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: sign_test dylib key profile\n"); return 64; }
    static char log[65536];
    int rc = sst_sign_macho(argv[1], argv[2], argc > 4 ? argv[4] : NULL, NULL, argv[3], "com.sidestep.payload", log, sizeof log);
    printf("--- sign rc=%d\n%s\n", rc, log);
    if (rc) return rc;
    ZMachO m;
    if (!m.Init(argv[1])) { printf("reopen failed\n"); return 10; }
    bool ok = m.CheckSignature();
    printf("--- CheckSignature: %s\n", ok ? "OK" : "FAILED");
    m.PrintInfo();
    return ok ? 0 : 11;
}
