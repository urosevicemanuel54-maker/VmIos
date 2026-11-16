//
//  vortex_host.c
//  Vortex
//
//  Host-process capability probes. Uses only APIs that are present on the
//  running system, resolved at runtime so a missing symbol reports "no"
//  instead of failing to launch.
//

#include "vortex_host.h"

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define VORTEX_CS_OPS_STATUS 0u
#define VORTEX_CS_DEBUGGED 0x10000000u
#define VORTEX_JIT_PROBE_BYTES 16384u

typedef void *(*VortexSecTaskCreateFromSelf)(CFAllocatorRef allocator);
typedef CFTypeRef (*VortexSecTaskCopyValueForEntitlement)(void *task,
                                                          CFStringRef entitlement,
                                                          CFErrorRef *error);
typedef int (*VortexCsOps)(pid_t pid, uint32_t ops, void *address, size_t size);
typedef void (*VortexJitWriteProtect)(int enabled);

static void *vortex_lookup(const char *framework, const char *symbol)
{
    void *handle = dlopen(framework, RTLD_LAZY);
    if (handle == NULL) {
        return NULL;
    }
    return dlsym(handle, symbol);
}

bool vortex_host_has_get_task_allow(void)
{
    static VortexSecTaskCreateFromSelf create_task = NULL;
    static VortexSecTaskCopyValueForEntitlement copy_value = NULL;
    static bool resolved = false;

    if (!resolved) {
        const char *security = "/System/Library/Frameworks/Security.framework/Security";
        create_task = (VortexSecTaskCreateFromSelf)vortex_lookup(security, "SecTaskCreateFromSelf");
        copy_value = (VortexSecTaskCopyValueForEntitlement)vortex_lookup(security,
                                                                         "SecTaskCopyValueForEntitlement");
        resolved = true;
    }

    if (create_task == NULL || copy_value == NULL) {
        return false;
    }

    void *task = create_task(NULL);
    if (task == NULL) {
        return false;
    }

    CFTypeRef value = copy_value(task, CFSTR("get-task-allow"), NULL);
    bool allowed = false;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            allowed = CFBooleanGetValue((CFBooleanRef)value);
        }
        CFRelease(value);
    }
    CFRelease(task);
    return allowed;
}

bool vortex_host_is_debugged(void)
{
    static VortexCsOps csops_fn = NULL;
    static bool resolved = false;

    if (!resolved) {
        csops_fn = (VortexCsOps)vortex_lookup("/usr/lib/libSystem.B.dylib", "csops");
        resolved = true;
    }
    if (csops_fn == NULL) {
        return false;
    }

    uint32_t status = 0;
    int result = csops_fn(getpid(), VORTEX_CS_OPS_STATUS, &status, sizeof(status));
    if (result != 0) {
        return false;
    }
    return (status & VORTEX_CS_DEBUGGED) != 0u;
}

bool vortex_host_jit_memory_available(void)
{
    void *region = mmap(NULL,
                        VORTEX_JIT_PROBE_BYTES,
                        PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_PRIVATE | MAP_ANON | MAP_JIT,
                        -1,
                        0);
    if (region == MAP_FAILED) {
        return false;
    }

    uint32_t *words = (uint32_t *)region;
    words[0] = 0xd65f03c0u; /* ret */
    uint32_t readback = ((volatile uint32_t *)region)[0];
    munmap(region, VORTEX_JIT_PROBE_BYTES);

    return readback == 0xd65f03c0u;
}

void vortex_host_jit_write_protect(bool protect)
{
    static VortexJitWriteProtect protect_fn = NULL;
    static bool resolved = false;

    if (!resolved) {
        protect_fn = (VortexJitWriteProtect)vortex_lookup("/usr/lib/libSystem.B.dylib",
                                                          "pthread_jit_write_protect_np");
        resolved = true;
    }
    if (protect_fn == NULL) {
        return;
    }
    protect_fn(protect ? 1 : 0);
}

bool vortex_host_tcp_reachable(const char *host, int port, int timeout_ms)
{
    if (host == NULL || port <= 0 || port > 65535) {
        return false;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &address.sin_addr) != 1) {
        return false;
    }

    int socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        return false;
    }

    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK);
    }

    int result = connect(socket_fd, (struct sockaddr *)&address, sizeof(address));
    bool reachable = false;

    if (result == 0) {
        reachable = true;
    } else if (errno == EINPROGRESS) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(socket_fd, &writable);

        struct timeval timeout;
        timeout.tv_sec = timeout_ms / 1000;
        timeout.tv_usec = (timeout_ms % 1000) * 1000;

        int ready = select(socket_fd + 1, NULL, &writable, NULL, &timeout);
        if (ready > 0) {
            int error = 0;
            socklen_t length = sizeof(error);
            if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0) {
                reachable = true;
            }
        }
    }

    close(socket_fd);
    return reachable;
}
