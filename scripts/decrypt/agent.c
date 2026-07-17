/*
 * agent.c — Native JVMTI agent that extracts the TWS AES-128 logKey
 * and writes it to a host-mounted directory.
 *
 * Two execution phases:
 *
 *  1. On Agent_OnAttach (immediately at JVM startup): try once.
 *     Most of the time this is too early — TWS auth hasn't completed
 *     and `twslaunch.jclient.login.e.t` is still null.
 *
 *  2. Background poll thread: every POLL_INTERVAL_MS, re-attempt the
 *     extraction. Each time we see a different key, write a new file
 *     `<KEYS_DIR>/key-<unix-ts>.hex` so old log files can always be
 *     matched with the key that was live when they were written.
 *
 * The key filename pattern (timestamp-based, not session-id-based)
 * means the host can:
 *   - list keys sorted by mtime to see which one is current
 *   - keep all keys forever, decrypt any historical log
 *   - use the most-recent key for "I just want today's logs"
 *
 * Compile:
 *   gcc -O2 -fPIC -shared -o libagent.so agent.c \
 *       -I$JDK/include -I$JDK/include/linux
 *
 * JVM flag to load:
 *   -agentpath:/home/tws/.tws-tools/libagent.so
 *
 * Output:
 *   /home/tws/jts/logs/keys/key-<unix-ts>.hex   (32-char lowercase hex)
 *   /home/tws/jts/logs/keys/current -> key-<unix-ts>.hex  (symlink)
 *   /tmp/agent-trace.log                        (verbose trace)
 */
#include <jvmti.h>
#include <jni.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>

#define TRACE_PATH    "/tmp/agent-trace.log"
#define KEYS_DIR      "/home/tws/jts/logs/keys"
#define CURRENT_LINK   KEYS_DIR "/current"
#define POLL_INTERVAL_MS 15000

static JavaVM *g_vm = NULL;
static pthread_t g_poller;
static volatile int g_should_stop = 0;

/* ---------- trace helpers ---------- */

static FILE *g_trace_fp = NULL;
static pthread_mutex_t g_trace_mu = PTHREAD_MUTEX_INITIALIZER;

static void trace_open(void) {
    if (g_trace_fp) return;
    g_trace_fp = fopen(TRACE_PATH, "a");
}

static void trace(const char *msg) {
    pthread_mutex_lock(&g_trace_mu);
    trace_open();
    if (g_trace_fp) {
        time_t now = time(NULL);
        struct tm tm;
        char tbuf[32];
        localtime_r(&now, &tm);
        strftime(tbuf, sizeof tbuf, "%Y-%m-%dT%H:%M:%S", &tm);
        fprintf(g_trace_fp, "[%s] %s\n", tbuf, msg);
        fflush(g_trace_fp);
    }
    pthread_mutex_unlock(&g_trace_mu);
}

static void tracef(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    trace(buf);
}

/* ---------- key extraction ---------- */

/* Compare `n` bytes at `a` and `b`. */
static int bytes_eq(const unsigned char *a, const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) if (a[i] != b[i]) return 0;
    return 1;
}

/* Write `hex` (length `n`) to KEYS_DIR/key-<ts>.hex and update the
 * `current` symlink. No-op if `hex` is NULL or empty, or identical
 * to the most-recent key (we already have a file for it).
 */
static unsigned char g_last_key[32] = {0};
static int g_last_key_len = 0;

static void maybe_write_key(const unsigned char *bytes, int n) {
    if (!bytes || n <= 0) return;
    if (n == g_last_key_len && bytes_eq(bytes, g_last_key, n)) {
        /* Same key as last time — just refresh the `current` symlink
         * to point at the existing file (in case it was deleted) and
         * skip the write. */
        return;
    }
    memcpy(g_last_key, bytes, n);
    g_last_key_len = n;
    if (!bytes || n <= 0) return;
    char ts[32];
    snprintf(ts, sizeof ts, "%lld", (long long)time(NULL));
    char path[256];
    snprintf(path, sizeof path, "%s/key-%s.hex", KEYS_DIR, ts);

    /* mkdir -p for the keys dir; ignore EEXIST. Walk up the path
 * and create each segment. */
    {
        char path[256];
        snprintf(path, sizeof path, "%s", KEYS_DIR);
        for (char *p = path + 1; *p; p++) {
            if (*p == '/') {
                *p = '\0';
                mkdir(path, 0777);  /* ignore errors */
                *p = '/';
            }
        }
        mkdir(path, 0777);  /* final segment, ignore EEXIST */
    }

    /* Write hex. */
    FILE *f = fopen(path, "w");
    if (!f) {
        tracef("open(%s) failed: errno=%d", path, errno);
        return;
    }
    static const char H[] = "0123456789abcdef";
    for (int i = 0; i < n; i++) {
        fputc(H[(bytes[i] >> 4) & 0xf], f);
        fputc(H[bytes[i] & 0xf], f);
    }
    fclose(f);
    tracef("wrote key file %s (len=%d)", path, n);

    /* Update `current` symlink (best-effort). */
    char target[64];
    snprintf(target, sizeof target, "key-%s.hex", ts);
    unlink(CURRENT_LINK);
    if (symlink(target, CURRENT_LINK) != 0) {
        tracef("symlink current -> %s failed: errno=%d", target, errno);
    }
}

/* Returns the key length on success (16/24/32), or -1 on failure.
 * Caller does NOT own the returned bytes — they reference a JNI
 * local ref that becomes invalid when the thread detaches.
 */
static int extract_key(void) {
    if (!g_vm) return -1;

    JNIEnv *jni = NULL;
    /* Attach current (poller) thread. */
    jint res = (*g_vm)->AttachCurrentThread(g_vm, (void **)&jni, NULL);
    if (res != JNI_OK || !jni) {
        tracef("AttachCurrentThread failed: %d", (int)res);
        return -1;
    }

    /* twslaunch.jsetting.H */
    jclass clsH = (*jni)->FindClass(jni, "twslaunch/jsetting/H");
    if (!clsH) { (*jni)->ExceptionClear(jni); (*g_vm)->DetachCurrentThread(g_vm); return -1; }
    jmethodID mid_a = (*jni)->GetStaticMethodID(jni, clsH, "a",
        "()Ltwslaunch/jclient/login/l;");
    if (!mid_a) { (*jni)->ExceptionClear(jni); (*g_vm)->DetachCurrentThread(g_vm); return -1; }

    jobject lInstance = (*jni)->CallStaticObjectMethod(jni, clsH, mid_a);
    if (!lInstance || (*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionClear(jni);
        (*g_vm)->DetachCurrentThread(g_vm);
        return -1;
    }

    jclass clsL = (*jni)->FindClass(jni, "twslaunch/jclient/login/l");
    if (!clsL) { (*jni)->ExceptionClear(jni); (*g_vm)->DetachCurrentThread(g_vm); return -1; }
    jmethodID mid_u = (*jni)->GetMethodID(jni, clsL, "u", "()[B");
    if (!mid_u) { (*jni)->ExceptionClear(jni); (*g_vm)->DetachCurrentThread(g_vm); return -1; }

    jbyteArray keyArr = (*jni)->CallObjectMethod(jni, lInstance, mid_u);
    if (!keyArr || (*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionClear(jni);
        (*g_vm)->DetachCurrentThread(g_vm);
        return -1;
    }

    jsize len = (*jni)->GetArrayLength(jni, keyArr);
    if (len != 16 && len != 24 && len != 32) {
        tracef("unexpected key length %d", (int)len);
        (*g_vm)->DetachCurrentThread(g_vm);
        return -1;
    }

    jbyte *bytes = (*jni)->GetByteArrayElements(jni, keyArr, NULL);
    int result = -1;
    if (bytes) {
        maybe_write_key((const unsigned char *)bytes, (int)len);
        result = (int)len;
        (*jni)->ReleaseByteArrayElements(jni, keyArr, bytes, JNI_ABORT);
    }
    (*g_vm)->DetachCurrentThread(g_vm);
    return result;
}

/* ---------- poller thread ---------- */

static void *poll_thread(void *arg) {
    (void)arg;
    trace("poll thread: start");
    int consecutive_failures = 0;
    while (!g_should_stop) {
        int rc = extract_key();
        if (rc > 0) {
            tracef("poll: extracted key (len=%d)", rc);
            consecutive_failures = 0;
        } else {
            consecutive_failures++;
            if (consecutive_failures % 10 == 1) {
                tracef("poll: no key yet (%d consecutive failures)",
                       consecutive_failures);
            }
        }
        /* Sleep in 1s slices so we shut down promptly. */
        for (int i = 0; i < POLL_INTERVAL_MS / 1000 && !g_should_stop; i++) {
            sleep(1);
        }
    }
    trace("poll thread: stop");
    return NULL;
}

/* ---------- JVMTI entry points ---------- */

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM *vm, char *options, void *reserved) {
    (void)options; (void)reserved;
    trace("Agent_OnAttach: start");

    g_vm = vm;

    /* Try once immediately. Almost always fails because the auth flow
     * hasn't run yet, but no harm in trying. */
    int rc = extract_key();
    tracef("Agent_OnAttach: initial extract returned %d", rc);

    /* Start the background poller. */
    if (pthread_create(&g_poller, NULL, poll_thread, NULL) != 0) {
        trace("Agent_OnAttach: pthread_create failed");
        return JNI_ERR;
    }
    /* Detach the poller thread — it manages its own JNI attach loop. */
    pthread_detach(g_poller);

    trace("Agent_OnAttach: end (poller running)");
    return JNI_OK;
}

JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    return Agent_OnAttach(vm, options, reserved);
}