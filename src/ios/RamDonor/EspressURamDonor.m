// SPDX-License-Identifier: MPL-2.0
//
// EspressU RAM donor extension.
//
// iOS enforces a memory limit per process, so a game that needs more than EspressU's own limit gets
// jetsammed. Every app extension is its own process with its own budget. The host starts a few of these,
// each one allocates memory chunks and hands them back as xpc_shmem objects, and the host maps those
// chunks into the guest address space (see src/ios/Bridge/IOSRamDonor.mm).
//
// Nothing here talks to the network or touches files; the extension only allocates and shares memory.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <os/proc.h>
#import <os/log.h>
#import <xpc/xpc.h>
#import <stdlib.h>
#import <unistd.h>

#import "ESPRamDonor.h"

// NSXPCListenerEndpoint's raw xpc_endpoint_t. Private, but stable since iOS 8.
@interface NSXPCListenerEndpoint (ESPPrivate)
- (xpc_endpoint_t)_endpoint;
@end

// Safety margin kept free in the donor so it isn't jetsammed by its own bookkeeping.
static const uint64_t kDonorHeadroom = 24ull * 1024 * 1024;

static os_log_t ESPLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.espressu.EspressU.RamDonor", "donor"); });
    return log;
}

#pragma mark - NSXPCDecoder validation hook
//
// The host passes its endpoint in NSExtensionItem.userInfo. iOS decodes extension input items with an
// allow-list of plain property-list classes, so NSXPCListenerEndpoint is rejected before beginRequest runs.
// That decoding happens before any of our own code gets a turn, so the check has to be relaxed from a
// constructor. It is restored as soon as the endpoint has been read.

static IMP sOriginalValidate;
static Method sValidateMethod;

static BOOL ESPAllowEndpointDecoding(id self, SEL _cmd, Class cls, NSString *key, BOOL allowInvocations)
{
    return YES;
}

static void ESPInstallDecoderHook(void)
{
    Class decoder = NSClassFromString(@"NSXPCDecoder");
    sValidateMethod = class_getInstanceMethod(decoder, NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (!sValidateMethod)
    {
        os_log_error(ESPLog(), "Loaded in pid %d, but NSXPCDecoder validation hook was NOT found", getpid());
        return;
    }
    sOriginalValidate = method_setImplementation(sValidateMethod, (IMP)ESPAllowEndpointDecoding);
    os_log(ESPLog(), "Loaded in pid %d, decoder validation relaxed", getpid());
}

static void ESPRemoveDecoderHook(void)
{
    if (sValidateMethod && sOriginalValidate)
        method_setImplementation(sValidateMethod, sOriginalValidate);
    sOriginalValidate = NULL;
}

__attribute__((constructor)) static void ESPRamDonorLoaded(void)
{
    ESPInstallDecoderHook();
}

#pragma mark - Allocation bookkeeping

@interface ESPChunk : NSObject
{
@public
    mach_vm_address_t address;
    mach_vm_size_t size;
}
@end
@implementation ESPChunk
@end

static NSMutableDictionary<NSNumber *, ESPChunk *> *sChunks;
static uint64_t sNextChunkID = 1;

static uint64_t ESPAvailable(void)
{
    const uint64_t available = os_proc_available_memory();
    return available > kDonorHeadroom ? available - kDonorHeadroom : 0;
}

static void ESPReplyError(xpc_object_t reply, const char *message)
{
    xpc_dictionary_set_bool(reply, ESP_DONOR_KEY_OK, false);
    xpc_dictionary_set_string(reply, ESP_DONOR_KEY_ERROR, message);
}

static void ESPHandleAlloc(xpc_object_t request, xpc_object_t reply)
{
    const uint64_t pageSize = (uint64_t)vm_page_size;
    uint64_t size = xpc_dictionary_get_uint64(request, ESP_DONOR_KEY_SIZE);
    const bool prefault = xpc_dictionary_get_bool(request, ESP_DONOR_KEY_PREFAULT);
    if (size == 0)
    {
        ESPReplyError(reply, "Refusing to create a zero sized region");
        return;
    }
    size = (size + pageSize - 1) & ~(pageSize - 1);
    if (size > ESPAvailable())
    {
        ESPReplyError(reply, "Not enough memory left in this donor");
        return;
    }

    mach_vm_address_t address = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS)
    {
        ESPReplyError(reply, mach_error_string(kr));
        return;
    }
    if (prefault)
    {
        // Touch every page so the memory is resident and charged to this process.
        volatile uint8_t *bytes = (volatile uint8_t *)(uintptr_t)address;
        for (uint64_t offset = 0; offset < size; offset += pageSize)
            bytes[offset] = 0;
    }

    xpc_object_t shmem = xpc_shmem_create((void *)(uintptr_t)address, (size_t)size);
    if (!shmem)
    {
        mach_vm_deallocate(mach_task_self(), address, size);
        ESPReplyError(reply, "xpc_shmem_create returned NULL");
        return;
    }

    ESPChunk *chunk = [ESPChunk new];
    chunk->address = address;
    chunk->size = size;
    const uint64_t chunkID = sNextChunkID++;
    sChunks[@(chunkID)] = chunk;

    xpc_dictionary_set_bool(reply, ESP_DONOR_KEY_OK, true);
    xpc_dictionary_set_uint64(reply, ESP_DONOR_KEY_ID, chunkID);
    xpc_dictionary_set_uint64(reply, ESP_DONOR_KEY_SIZE, size);
    xpc_dictionary_set_value(reply, ESP_DONOR_KEY_SHMEM, shmem);
}

static void ESPHandleFree(xpc_object_t request, xpc_object_t reply)
{
    NSNumber *key = @(xpc_dictionary_get_uint64(request, ESP_DONOR_KEY_ID));
    ESPChunk *chunk = sChunks[key];
    if (chunk)
    {
        mach_vm_deallocate(mach_task_self(), chunk->address, chunk->size);
        [sChunks removeObjectForKey:key];
    }
    xpc_dictionary_set_bool(reply, ESP_DONOR_KEY_OK, chunk != nil);
}

#pragma mark - Extension entry point

@interface ESPRamDonorHandler : NSObject <NSExtensionRequestHandling>
{
    xpc_connection_t _channel;
}
@end

@implementation ESPRamDonorHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    NSArray *items = context.inputItems;
    os_log(ESPLog(), "beginRequest with %lu input item(s)", (unsigned long)items.count);

    NSXPCListenerEndpoint *endpoint = nil;
    NSArray *seenKeys = nil;
    for (id item in items)
    {
        if (![item isKindOfClass:NSExtensionItem.class])
            continue;
        NSDictionary *info = ((NSExtensionItem *)item).userInfo;
        seenKeys = info.allKeys;
        id candidate = info[@ESP_DONOR_USERINFO_ENDPOINT];
        if ([candidate isKindOfClass:NSXPCListenerEndpoint.class])
            endpoint = candidate;
        else if (candidate)
            os_log_error(ESPLog(), "The endpoint decoded as %{public}@, not an NSXPCListenerEndpoint", NSStringFromClass([candidate class]));
    }
    ESPRemoveDecoderHook();

    xpc_endpoint_t raw = [endpoint respondsToSelector:@selector(_endpoint)] ? [endpoint _endpoint] : nil;
    if (!raw)
    {
        os_log_error(ESPLog(), "Started, but the request carried no usable endpoint (userInfo keys: %{public}@)", seenKeys);
        [context completeRequestReturningItems:nil completionHandler:nil];
        return;
    }

    sChunks = [NSMutableDictionary new];
    xpc_connection_t channel = xpc_connection_create_from_endpoint(raw);
    _channel = channel;

    xpc_connection_set_event_handler(channel, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
        {
            os_log(ESPLog(), "Channel error, exiting: %{public}s", xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
            exit(0);
        }
        if (xpc_get_type(event) != XPC_TYPE_DICTIONARY)
            return;

        const char *op = xpc_dictionary_get_string(event, ESP_DONOR_KEY_OP);
        if (!op)
            return;
        if (strcmp(op, ESP_DONOR_OP_QUIT) == 0)
            exit(0);

        xpc_object_t reply = xpc_dictionary_create_reply(event);
        if (!reply)
            return;
        if (strcmp(op, ESP_DONOR_OP_ALLOC) == 0)
            ESPHandleAlloc(event, reply);
        else if (strcmp(op, ESP_DONOR_OP_FREE) == 0)
            ESPHandleFree(event, reply);
        else
            ESPReplyError(reply, "Unknown request");
        xpc_connection_send_message(xpc_dictionary_get_remote_connection(event), reply);
    });
    xpc_connection_resume(channel);

    os_log(ESPLog(), "Sending host handshake, pid %d", getpid());
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, ESP_DONOR_KEY_OP, ESP_DONOR_OP_HELLO);
    xpc_dictionary_set_int64(hello, ESP_DONOR_KEY_PID, getpid());
    xpc_dictionary_set_uint64(hello, ESP_DONOR_KEY_AVAILABLE, ESPAvailable());
    xpc_connection_send_message(channel, hello);
    os_log(ESPLog(), "Ready, pid %d", getpid());

    // The request is deliberately never completed: the extension has to stay alive for as long as the host
    // holds its memory. It exits when the host closes the channel or sends "quit".
}

@end
