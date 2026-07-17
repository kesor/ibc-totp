/*
 * agent.c — Native JVMTI agent that extracts the TWS AES-128 logKey.
 *
 * Design notes
 * ------------
 *
 * Loading this agent via `-agentpath:` at TWS JVM startup crashes the
 * JVM with SIGSEGV during Threads::create_vm. We don't fully
 * understand why — likely an interaction between Zulu 21's TLAB init
 * and JVMTI's on-load machinery. The same agent works fine when
 * attached LATER via `jcmd JVMTI.agent_load` after TWS is fully
 * running.
 *
 * The workaround: do nothing in Agent_OnAttach. Just spawn a
 * pthread that, after a short delay, attempts the extraction. By
 * the time the thread runs (even when attached at startup), the JVM
 * is past TLAB init.
 *
 * If VMInit IS available (we can detect it via the JVMTI env), we
 * register the VMInit callback too — it's the safer place to do
 * real work when attaching at startup.
 *
 * Output:
 *   /home/tws/jts/logs/keys/key-<unix-ts>.hex
 *   /home/tws/jts/logs/keys/current -> key-<ts>.hex (symlink)
 *   /tmp/agent-trace.log
 *
 * Compile:
 *   gcc -O2 -fPIC -shared -o libagent.so agent.c \
 *       -I$JDK/include -I$JDK/include/linux
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

#define TRACE_BASE       "/tmp/agent-trace"
#define KEYS_DIR         "/home/tws/jts/logs/keys"
#define CURRENT_LINK     KEYS_DIR "/current"
#define POLL_INTERVAL_MS 15000
#define STARTUP_DELAY_MS 3000   /* give the JVM time to leave TLAB init */

static JavaVM *g_vm = NULL;
static pthread_t g_poller;
static volatile int g_should_stop = 0;
static char g_trace_path[256];

/* ---------- trace helpers ---------- */

static FILE *g_trace_fp = NULL;
static pthread_mutex_t g_trace_mu = PTHREAD_MUTEX_INITIALIZER;

static void trace_open(void) {
    if (g_trace_fp) return;
    /* Each attach writes to a unique trace file based on the agent's
     * PID + timestamp. This avoids the race where `rm + touch`
     * invalidates our fd. The script can cat all of them. */
    if (g_trace_path[0] == '\0') {
        snprintf(g_trace_path, sizeof g_trace_path, "%s-%d-%lld.log",
                 TRACE_BASE, (int)getpid(), (long long)time(NULL));
    }
    g_trace_fp = fopen(g_trace_path, "w");
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

static unsigned char g_last_key[32] = {0};
static int g_last_key_len = 0;

static int bytes_eq(const unsigned char *a, const unsigned char *b, int n) {
    for (int i = 0; i < n; i++) if (a[i] != b[i]) return 0;
    return 1;
}

static void maybe_write_key(const unsigned char *bytes, int n) {
    if (!bytes || n <= 0) return;
    if (n == g_last_key_len && bytes_eq(bytes, g_last_key, n)) {
        return;
    }
    memcpy(g_last_key, bytes, n);
    g_last_key_len = n;

    char path[256];
    snprintf(path, sizeof path, "%s", KEYS_DIR);
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(path, 0777);
            *p = '/';
        }
    }
    mkdir(path, 0777);

    char ts[32];
    snprintf(ts, sizeof ts, "%lld", (long long)time(NULL));
    snprintf(path, sizeof path, "%s/key-%s.hex", KEYS_DIR, ts);

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

    char target[64];
    snprintf(target, sizeof target, "key-%s.hex", ts);
    unlink(CURRENT_LINK);
    if (symlink(target, CURRENT_LINK) != 0) {
        tracef("symlink current -> %s failed: errno=%d", target, errno);
    }
}

static int extract_key(void) {
    if (!g_vm) return -1;

    struct JavaVM_ {
        const struct JNIInvokeInterface_ *functions;
    } *jvm = (struct JavaVM_ *)g_vm;

    JNIEnv *jni = NULL;
    jint res = jvm->functions->AttachCurrentThread(g_vm, (void **)&jni, NULL);
    if (res != JNI_OK || !jni) {
        tracef("extract_key: AttachCurrentThread failed: %d", (int)res);
        return -1;
    }

#define DETACH(R) do { jvm->functions->DetachCurrentThread(g_vm); return R; } while (0)

    jclass clsH = (*jni)->FindClass(jni, "twslaunch/jsetting/H");
    if (!clsH) { (*jni)->ExceptionClear(jni); DETACH(-1); }
    jmethodID mid_a = (*jni)->GetStaticMethodID(jni, clsH, "a",
        "()Ltwslaunch/jclient/login/l;");
    if (!mid_a) { (*jni)->ExceptionClear(jni); DETACH(-1); }

    jobject lInstance = (*jni)->CallStaticObjectMethod(jni, clsH, mid_a);
    if (!lInstance || (*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionClear(jni);
        DETACH(-1);
    }

    jclass clsL = (*jni)->FindClass(jni, "twslaunch/jclient/login/l");
    if (!clsL) { (*jni)->ExceptionClear(jni); DETACH(-1); }
    jmethodID mid_u = (*jni)->GetMethodID(jni, clsL, "u", "()[B");
    if (!mid_u) { (*jni)->ExceptionClear(jni); DETACH(-1); }

    jbyteArray keyArr = (*jni)->CallObjectMethod(jni, lInstance, mid_u);
    if (!keyArr || (*jni)->ExceptionCheck(jni)) {
        (*jni)->ExceptionClear(jni);
        DETACH(-1);
    }

    jsize len = (*jni)->GetArrayLength(jni, keyArr);
    if (len != 16 && len != 24 && len != 32) {
        tracef("unexpected key length %d", (int)len);
        DETACH(-1);
    }

    jbyte *bytes = (*jni)->GetByteArrayElements(jni, keyArr, NULL);
    int result = -1;
    if (bytes) {
        maybe_write_key((const unsigned char *)bytes, (int)len);
        result = (int)len;
        (*jni)->ReleaseByteArrayElements(jni, keyArr, bytes, JNI_ABORT);
    }
    DETACH(result);
}

/* ---------- poller thread ---------- */

static void *poll_thread(void *arg) {
    (void)arg;
    /* Sleep first to give the JVM time to leave startup. */
    for (int i = 0; i < STARTUP_DELAY_MS / 1000 && !g_should_stop; i++) {
        sleep(1);
    }
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
        for (int i = 0; i < POLL_INTERVAL_MS / 1000 && !g_should_stop; i++) {
            sleep(1);
        }
    }
    trace("poll thread: stop");
    return NULL;
}

/* ---------- JVMTI entry points ---------- */

static void on_vm_init(jvmtiEnv *jvmti_env, JNIEnv *jni_env, jobject arg) {
    (void)jvmti_env; (void)jni_env; (void)arg;
    trace("VMInit: fire");

    /* Try once. Most TWS startups take 10-30s for auth, so this
     * almost always returns null. The poller will catch the key. */
    int rc = extract_key();
    tracef("VMInit: initial extract returned %d", rc);

    /* If we somehow didn't start the poller yet (because VMInit
     * fired before Agent_OnAttach's pthread_create ran — unlikely
     * but possible), start it now. */
    if (pthread_create(&g_poller, NULL, poll_thread, NULL) != 0) {
        trace("VMInit: pthread_create failed");
        return;
    }
    pthread_detach(g_poller);
    trace("VMInit: end (poller running)");
}

JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM *vm, char *options, void *reserved) {
    (void)options; (void)reserved;
    trace("Agent_OnAttach: start");

    g_vm = vm;

    /* Try to register the VMInit callback. If the JVM is past init
     * (we were attached after startup), VMInit will never fire —
     * the poller thread spawned below is the fallback. */
    {
        struct JavaVM_ {
            const struct JNIInvokeInterface_ *functions;
        } *jvm = (struct JavaVM_ *)vm;
        jvmtiEnv *jvmti = NULL;
        jint res = jvm->functions->GetEnv(vm, (void **)&jvmti, JVMTI_VERSION_1_2);
        if (res == JNI_OK && jvmti) {
            jvmtiEventCallbacks cbs = {0};
            cbs.VMInit = on_vm_init;
            res = (*jvmti)->SetEventCallbacks(jvmti, &cbs, sizeof cbs);
            if (res == JNI_OK) {
                res = (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE,
                                                          JVMTI_EVENT_VM_INIT, NULL);
                if (res == JNI_OK) {
                    trace("setup: VMInit callback registered");
                } else {
                    tracef("setup: SetEventNotificationMode failed: %d", (int)res);
                }
            } else {
                tracef("setup: SetEventCallbacks failed: %d", (int)res);
            }
        } else {
            tracef("setup: GetEnv failed: %d (no JVMTI — late attach?)", (int)res);
        }
    }

    /* Always spawn the poller thread. If VMInit also fires, both
     * might race to start it — we tolerate the duplicate. */
    if (pthread_create(&g_poller, NULL, poll_thread, NULL) != 0) {
        trace("Agent_OnAttach: pthread_create failed");
        return JNI_ERR;
    }
    pthread_detach(g_poller);

    trace("Agent_OnAttach: end");
    return JNI_OK;
}

JNIEXPORT jint JNICALL Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    return Agent_OnAttach(vm, options, reserved);
}