// SPDX-License-Identifier: MPL-2.0
//
// Wire protocol shared by the RAM donor extension (EspressURamDonor.appex) and the host side
// in Cemu.framework (IOSRamDonor.mm). Messages are plain XPC dictionaries.
//
//   donor -> host   {op:"hello", pid:int64, available:uint64}          sent once after connecting
//   host  -> donor  {op:"alloc", size:uint64, prefault:bool}           reply {ok, id, size, shmem | error}
//   host  -> donor  {op:"free",  id:uint64}                            reply {ok}
//   host  -> donor  {op:"quit"}                                        donor exits
//
// This header must stay free of Objective-C so both targets (and C++) can include it.

#pragma once

#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

// Raises this process's own jetsam memory limit. Needs the private entitlement
// com.apple.private.memorystatus (available when installed with TrollStore); without it the call is
// refused and this returns EPERM. Returns 0 on success, otherwise an errno value.
static inline int ESPLiftJetsamLimit(uint32_t megabytes)
{
    typedef int (*MemorystatusControl)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);
    MemorystatusControl control = (MemorystatusControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!control)
        return ENOSYS;
    const uint32_t kMemorystatusCmdSetJetsamTaskLimit = 6;
    return control(kMemorystatusCmdSetJetsamTaskLimit, getpid(), megabytes, NULL, 0) == 0 ? 0 : errno;
}

// Second way to raise the limit: MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES. With `fatal` false the limit is
// soft, so going past it no longer gets the process killed. Same entitlement as above; 0 or an errno value.
static inline int ESPSetMemlimitProperties(uint32_t megabytes, bool fatal)
{
    typedef int (*MemorystatusControl)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);
    MemorystatusControl control = (MemorystatusControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!control)
        return ENOSYS;
    struct { int32_t active; uint32_t activeAttr; int32_t inactive; uint32_t inactiveAttr; } props;
    props.active = props.inactive = (int32_t)megabytes;
    props.activeAttr = props.inactiveAttr = fatal ? 1u : 0u; // MEMORYSTATUS_MEMLIMIT_ATTR_FATAL = 0x1
    const uint32_t kMemorystatusCmdSetMemlimitProperties = 8;
    return control(kMemorystatusCmdSetMemlimitProperties, getpid(), 0, &props, sizeof(props)) == 0 ? 0 : errno;
}

// Sets this process's jetsam priority band (MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES). A higher band is killed
// later when the whole phone runs short of memory. Same entitlement as above; 0 or an errno value. iOS may put
// the band back when the app changes state, so callers re-apply it.
static inline int ESPSetJetsamPriority(int32_t priority)
{
    typedef int (*MemorystatusControl)(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size);
    MemorystatusControl control = (MemorystatusControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (!control)
        return ENOSYS;
    struct { int32_t priority; uint64_t userData; } props;
    props.priority = priority;
    props.userData = 0;
    const uint32_t kMemorystatusCmdSetPriorityProperties = 2;
    return control(kMemorystatusCmdSetPriorityProperties, getpid(), 0, &props, sizeof(props)) == 0 ? 0 : errno;
}

#define ESP_DONOR_KEY_OP        "op"
#define ESP_DONOR_KEY_PID       "pid"
#define ESP_DONOR_KEY_AVAILABLE "available"
#define ESP_DONOR_KEY_SIZE      "size"
#define ESP_DONOR_KEY_ID        "id"
#define ESP_DONOR_KEY_OK        "ok"
#define ESP_DONOR_KEY_SHMEM     "shmem"
#define ESP_DONOR_KEY_ERROR     "error"
#define ESP_DONOR_KEY_PREFAULT  "prefault"
#define ESP_DONOR_KEY_PURGEABLE "purgeable"
#define ESP_DONOR_KEY_FOOTPRINT "footprint"

#define ESP_DONOR_OP_HELLO "hello"
#define ESP_DONOR_OP_ALLOC "alloc"
#define ESP_DONOR_OP_FREE  "free"
#define ESP_DONOR_OP_QUIT  "quit"
#define ESP_DONOR_OP_STATUS "status"

// NSExtensionItem.userInfo key that carries the host's NSXPCListenerEndpoint.
#define ESP_DONOR_USERINFO_ENDPOINT "endpoint"  // use as @ESP_DONOR_USERINFO_ENDPOINT in Objective-C
