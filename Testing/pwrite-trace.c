/* Records every positioned read and write a process makes, below everything it believes about them.
 *
 * Written for one question. A card came back from a run with 177 files whose data sat exactly 65,536
 * bytes past where it belonged, while every other test came back clean: the reader put 190,000 large
 * transfers exactly where it was told, and an image matching the card in extent, cluster size, fill
 * level and contents moved 388,624 objects with all 273,092 files byte-identical. Those cannot both
 * be the whole story, so this settles it from underneath — it logs the offset actually handed to
 * pwrite, with a hash of every cluster the call carries, before the kernel sees it.
 *
 * Afterwards each cluster on the medium is compared against what the log says should be at that
 * offset. If the log holds the right content against the right offset for a cluster that ends up
 * wrong, the fault is below this line. If it holds that content against an offset 65,536 bytes high,
 * the fault is above, and the record names the call. That is write verification performed from
 * outside, which is why it needs no change to the tool: the configuration under test stays exactly
 * the binary that failed.
 *
 * It also caps what the device reports. An image advertises a 2 MiB maximum and a USB card reader
 * 131,072, so a run against an image chunks at a megabyte and never enters the regime the card runs
 * in — which is why this family of fault has never once appeared against an image. FR_MAXTRANSFER
 * makes an image lie the way the card does.
 *
 * Build: clang -O2 -dynamiclib -o libpwrite-trace.dylib pwrite-trace.c
 * Use:   FR_TRACE=log FR_MAXTRANSFER=131072 \
 *          DYLD_INSERT_LIBRARIES=./libpwrite-trace.dylib fatrabbit /dev/rdiskN ...
 *
 * DYLD_INSERT_LIBRARIES is stripped for root and setuid processes, so this is silently inert under
 * `sudo`. Chmod the device node and run as yourself, or the run costs an hour and records nothing.
 */

#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

/* One hash per cluster, so a record maps intended offsets to content at the granularity the
 * filesystem allocates in. 16384 is the cluster size of the volume this was written for; a volume
 * with a different one still verifies, just at a coarser or finer grain than its clusters. */
#define CHUNK 16384

static int log_fd = -1;
static long long cap = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

/* `_IOR('d', 70|71, uint64_t)` from <sys/disk.h>: the read and write transfer maxima. Written out
 * because they are macros, and macros of this shape do not come across. */
#define DKIOCGETMAXBYTECOUNTREAD  0x40086446UL
#define DKIOCGETMAXBYTECOUNTWRITE 0x40086447UL

__attribute__((constructor))
static void start(void) {
    const char *path = getenv("FR_TRACE");
    if (path) log_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    const char *value = getenv("FR_MAXTRANSFER");
    if (value) cap = atoll(value);
}

/* FNV-1a, 64-bit. Short enough to be obviously correct, which is the only property wanted here: a
 * collision would be a wrong answer to the one question being asked. */
static unsigned long long fnv(const unsigned char *p, size_t n) {
    unsigned long long h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* One record per call: kind, descriptor, offset, length, what the call returned, the alignment of
 * the buffer handed over, then a hash per cluster. A short or failed transfer is recorded as it
 * happened rather than as it was asked for.
 *
 * The alignment is there because the device states a four-byte minimum segment alignment, and a
 * buffer that only just meets it may be bounced by the driver where a page-aligned one is not —
 * which is a difference between two ways of issuing the same write, and therefore a candidate for
 * why one of them loses data. It is recorded as the low bits of the address rather than the
 * address, which is all that matters and does not leak the layout of the process. */
static void record(char kind, int fd, const void *buf, size_t len, off_t off, ssize_t ret) {
    if (log_fd < 0) return;
    char line[64 * 1024];
    int n = snprintf(line, sizeof line, "%c %d %lld %zu %zd a%u", kind, fd, (long long)off, len,
                     ret, (unsigned)((unsigned long)buf & 4095));
    const unsigned char *p = buf;
    for (size_t at = 0; at + CHUNK <= len && n < (int)sizeof line - 32; at += CHUNK) {
        n += snprintf(line + n, sizeof line - n, " %016llx", fnv(p + at, CHUNK));
    }
    n += snprintf(line + n, sizeof line - n, "\n");
    pthread_mutex_lock(&lock);
    write(log_fd, line, n);        /* write(2), not pwrite(2) — this must not observe itself */
    pthread_mutex_unlock(&lock);
}

static ssize_t traced_pwrite(int fd, const void *buf, size_t len, off_t off) {
    ssize_t ret = pwrite(fd, buf, len, off);
    record('W', fd, buf, len, off, ret);
    return ret;
}

/* Barriers, recorded rather than inferred. A replay that has to guess where a commit synced can
 * only approximate the demand the run placed on the device, and the whole value of a replay is that
 * it does not approximate. */
static int traced_fsync(int fd) {
    int ret = fsync(fd);
    if (log_fd >= 0) {
        char line[64];
        int n = snprintf(line, sizeof line, "F %d %d\n", fd, ret);
        pthread_mutex_lock(&lock);
        write(log_fd, line, n);
        pthread_mutex_unlock(&lock);
    }
    return ret;
}

static ssize_t traced_pread(int fd, void *buf, size_t len, off_t off) {
    ssize_t ret = pread(fd, buf, len, off);
    record('R', fd, buf, len, off, ret);
    return ret;
}

/* Variadic in the replacement as well as the original, and that is not cosmetic: on Apple arm64 a
 * variadic argument is passed on the stack rather than in a register, so a replacement declared with
 * a fixed third parameter would read the wrong place and hand the kernel a garbage pointer. */
static int traced_ioctl(int fd, unsigned long request, ...) {
    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);
    int ret = ioctl(fd, request, arg);
    /* Every ioctl, not just the capped ones: DKIOCSYNCHRONIZECACHE is the other half of a barrier,
     * and the DKIOC queries are what identify which descriptor is the volume — so a later reader
     * never has to guess a descriptor from how often it was used. */
    if (log_fd >= 0) {
        char line[64];
        int n = snprintf(line, sizeof line, "I %d %lx %d\n", fd, request, ret);
        pthread_mutex_lock(&lock);
        write(log_fd, line, n);
        pthread_mutex_unlock(&lock);
    }
    if (ret == 0 && cap > 0 && arg &&
        (request == DKIOCGETMAXBYTECOUNTREAD || request == DKIOCGETMAXBYTECOUNTWRITE)) {
        unsigned long long *value = arg;
        if (*value > (unsigned long long)cap) {
            if (log_fd >= 0) {
                char line[128];
                int n = snprintf(line, sizeof line, "C %lx %llu -> %lld\n", request, *value, cap);
                write(log_fd, line, n);
            }
            *value = (unsigned long long)cap;
        }
    }
    return ret;
}

/* The __interpose section is how dyld is told to swap one symbol for another without patching the
 * target, so the tool is observed exactly as it shipped. Both entries are plain function pointers;
 * the cast through unsigned long is what the platform's own headers do. */
#define INTERPOSE(new, old)                                                        \
    __attribute__((used)) static const struct { const void *n; const void *o; }    \
    _interpose_##old __attribute__((section("__DATA,__interpose"))) =              \
        { (const void *)(unsigned long)&new, (const void *)(unsigned long)&old }

INTERPOSE(traced_pwrite, pwrite);
INTERPOSE(traced_pread, pread);
INTERPOSE(traced_ioctl, ioctl);
INTERPOSE(traced_fsync, fsync);
