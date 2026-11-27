#include "sst_signer.h"
#include "common.h"
#include "log.h"
#include "openssl.h"
#include "macho.h"
#include <mutex>
#include <string>

static std::string *g_capture = nullptr;
static void capture(const char *s) { if (g_capture && s) g_capture->append(s); }

extern "C" int sst_sign_macho(const char *machoPath, const char *keyPath, const char *certPath, const char *password,
                              const char *provPath, const char *identifier,
                              char *logBuf, size_t logLen)
{
    static std::mutex lock;              // zsign keeps global state; one signing at a time
    std::lock_guard<std::mutex> guard(lock);

    std::string log;
    g_capture = &log;
    g_zlogHook = capture;
    ZLog::SetLogLever(ZLog::E_INFO);

    int rc = 0;
    if (!machoPath || !keyPath || !provPath) {
        log += "missing argument\n";
        rc = 1;
    } else {
        ZSignAsset asset;
        // Init(cert, pkey, prov, entitle, password, adhoc, sha256Only, singleBinary).
        // Without a cert file (or one that doesn't match the key), zsign picks the
        // certificate in the profile that matches the key.
        if (!asset.Init(certPath ? certPath : "", keyPath, provPath, "", password ? password : "",
                        false, true, true)) {
            log += "ZSignAsset::Init failed (wrong key for this profile, or bad profile)\n";
            rc = 2;
        } else {
            log += "signer: " + asset.m_strSubjectCN + " (team " + asset.m_strTeamId + ")\n";
            ZMachO macho;
            if (!macho.Init(machoPath)) {
                log += "could not open Mach-O file\n";
                rc = 3;
            } else if (!macho.Sign(&asset, true, identifier ? identifier : "", "", "", "")) {
                log += "signing failed\n";
                rc = 4;
            }
        }
    }

    g_zlogHook = nullptr;
    g_capture = nullptr;
    if (logBuf && logLen) {
        size_t n = log.size() < logLen - 1 ? log.size() : logLen - 1;
        memcpy(logBuf, log.data(), n);
        logBuf[n] = 0;
    }
    return rc;
}
