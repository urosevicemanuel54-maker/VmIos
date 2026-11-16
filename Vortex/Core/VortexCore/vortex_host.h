//
//  vortex_host.h
//  Vortex
//
//  Host-process probes used by the JIT coordinator. Everything here reports
//  what the runtime actually says; nothing is inferred from the iOS version.
//

#ifndef VORTEX_HOST_H
#define VORTEX_HOST_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the `get-task-allow` entitlement of the running app through the
/// Security framework's SecTask SPI. Returns false when the entitlement is
/// absent or the SPI cannot be resolved.
bool vortex_host_has_get_task_allow(void);

/// True when the kernel reports CS_DEBUGGED for this process, i.e. a debugger
/// is attached. This is the signal both StikDebug and StikJIT produce.
bool vortex_host_is_debugged(void);

/// Attempts to create a MAP_JIT executable mapping, write a word into it and
/// read it back. Nothing is executed, so this cannot fault. Returns true only
/// when the mapping, the write and the read-back all succeeded.
bool vortex_host_jit_memory_available(void);

/// Switches the calling thread's JIT write protection (arm64 only). A no-op
/// where the API is unavailable.
void vortex_host_jit_write_protect(bool protect);

/// Attempts a TCP connection to host:port within `timeout_ms`. Returns true
/// only when the connection completes. Used to verify the LocalDevVPN
/// endpoint rather than assuming a VPN is active.
bool vortex_host_tcp_reachable(const char *host, int port, int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* VORTEX_HOST_H */
