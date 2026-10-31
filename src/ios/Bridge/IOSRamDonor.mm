// SPDX-License-Identifier: MPL-2.0

#include "IOSRamDonor.h"

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <xpc/xpc.h>

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <set>
#include <vector>

#include "../RamDonor/ESPRamDonor.h"

// NSExtension is private API; these are the same selectors StikJITHelperLauncher already relies on.
@protocol ESPExtension <NSObject>
+ (nullable instancetype)extensionWithIdentifier:(NSString*)identifier error:(NSError**)error;
- (void)beginExtensionRequestWithInputItems:(NSArray*)inputItems completion:(void (^)(NSUUID* _Nullable requestIdentifier))completion;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID*)requestIdentifier;
- (int)pidForRequestIdentifier:(NSUUID*)requestIdentifier;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID* requestIdentifier))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID* requestIdentifier, NSError* error))block;
@end

// Wraps a raw xpc_endpoint_t so it can travel inside an NSExtensionItem. Private, stable since iOS 8.
@interface NSXPCListenerEndpoint (ESPPrivate)
- (void)_setEndpoint:(xpc_endpoint_t)endpoint;
@end

extern "C" void cemu_bridge_log_checkpoint(const char* message);

namespace
{
	std::atomic<size_t> g_donatedBytes{ 0 };
	std::atomic<uint64_t> g_donorFootprint{ 0 }; // sum of the donors' own phys_footprint at the last refresh
	std::atomic<double> g_footprintRefreshedAt{ 0 };
	std::atomic<bool> g_limitLifted{ false };
	std::atomic<bool> g_limitVerified{ false }; // iOS reports a clearly larger limit after the change
	std::atomic<uint64_t> g_originalLimit{ 0 }; // what iOS reported before the lift (available + footprint)

	NSString* const kMemoryCapKey = @"espressu.ramDonor.memoryCapMB"; // default: 3072 (this app plus its donors)
	constexpr uint64_t kDefaultMemoryCapMB = 3072;
	constexpr uint64_t kMinMemoryCapMB = 1024;

	uint64_t OwnFootprintBytes()
	{
		task_vm_info_data_t info{};
		mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
		if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
			return 0;
		return (uint64_t)info.phys_footprint;
	}

	uint64_t MemoryCapBytes()
	{
		static uint64_t cap = []() -> uint64_t {
			NSInteger mb = [[NSUserDefaults standardUserDefaults] integerForKey:kMemoryCapKey];
			uint64_t value = mb > 0 ? (uint64_t)mb : kDefaultMemoryCapMB;
			if (value < kMinMemoryCapMB)
				value = kMinMemoryCapMB;
			if (value > 6144)
				value = 6144;
			return value << 20;
		}();
		return cap;
	}

	// User settings (NSUserDefaults).
	NSString* const kEnabledKey = @"espressu.ramDonor.enabled";     // default: on
	NSString* const kMaxDonorsKey = @"espressu.ramDonor.maxDonors"; // default: 4
	NSString* const kPrefaultKey = @"espressu.ramDonor.prefault";   // default: on (donor touches the pages, so they are charged to it)
	NSString* const kPurgeableKey = @"espressu.ramDonor.purgeable"; // default: off (experimental: purgeable memory is charged to its creator)

	constexpr NSInteger kDefaultMaxDonors = 4;
	constexpr NSInteger kHardMaxDonors = 8;
	constexpr double kSpawnTimeoutSeconds = 6.0;

	struct Donor
	{
		xpc_connection_t connection = nullptr;
		int64_t pid = 0;
		uint64_t available = 0; // bytes the donor reported it can still hand out
		bool alive = true;
		uint64_t footprint = 0; // the donor's own phys_footprint at the last status reply
	};

	struct Chunk
	{
		uintptr_t target = 0; // host address the chunk is mapped at
		size_t length = 0;
		size_t donorIndex = 0;
		uint64_t chunkId = 0;
	};

	// g_opMutex serialises the public API (and may be held while waiting on donors).
	// g_stateMutex protects the data the XPC event handlers touch and is only ever held briefly.
	std::mutex g_opMutex;
	std::mutex g_stateMutex;

	std::vector<Donor> g_donors;                // g_stateMutex
	std::string g_status = "RAM donor: not started"; // g_stateMutex
	dispatch_semaphore_t g_helloSemaphore;      // g_stateMutex

	std::vector<Chunk> g_chunks;                // g_opMutex
	std::vector<id<ESPExtension>> g_extensions; // g_opMutex
	std::vector<NSUUID*> g_requestIds;          // g_opMutex
	std::set<std::string> g_startedIdentifiers; // g_opMutex: extension copies already asked for a process
	xpc_connection_t g_listener = nullptr;      // g_opMutex
	dispatch_queue_t g_queue = nullptr;         // g_opMutex

	void SetStatus(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
	void SetStatus(const char* fmt, ...)
	{
		char buffer[256];
		va_list args;
		va_start(args, fmt);
		vsnprintf(buffer, sizeof(buffer), fmt, args);
		va_end(args);
		{
			std::lock_guard<std::mutex> lock(g_stateMutex);
			g_status = buffer;
		}
		NSLog(@"[RamDonor] %s", buffer);
		// Also into CemuCrashLog.txt, so a device log shows what the donors did.
		char line[300];
		snprintf(line, sizeof(line), "RAMDONOR: %s", buffer);
		cemu_bridge_log_checkpoint(line);
	}

	// Every embedded copy of the donor extension. iOS can answer several requests for one extension with a single
	// process, which shares one memory allowance, so each copy has its own bundle identifier and is asked once.
	NSArray<NSString*>* DonorIdentifiers()
	{
		NSURL* plugIns = NSBundle.mainBundle.builtInPlugInsURL;
		if (!plugIns)
			return @[];
		NSArray<NSURL*>* entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:plugIns includingPropertiesForKeys:nil options:0 error:nil];
		NSMutableArray<NSString*>* identifiers = [NSMutableArray array];
		for (NSURL* entry in entries)
		{
			if (![entry.lastPathComponent hasPrefix:@"EspressURamDonor"] || ![entry.pathExtension isEqualToString:@"appex"])
				continue;
			NSString* identifier = [NSBundle bundleWithURL:entry].bundleIdentifier;
			if (identifier.length)
				[identifiers addObject:identifier];
		}
		return [identifiers sortedArrayUsingSelector:@selector(compare:)];
	}

	bool UserEnabled()
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		return [defaults objectForKey:kEnabledKey] ? [defaults boolForKey:kEnabledKey] : true;
	}

	size_t MaxDonors()
	{
		NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kMaxDonorsKey];
		if (value <= 0)
			value = kDefaultMaxDonors;
		return (size_t)std::min(value, kHardMaxDonors);
	}

	bool Prefault()
	{
		NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
		return [defaults objectForKey:kPrefaultKey] ? [defaults boolForKey:kPrefaultKey] : true;
	}

	bool Purgeable()
	{
		return [NSUserDefaults.standardUserDefaults boolForKey:kPurgeableKey];
	}

	size_t LiveDonorCount()
	{
		std::lock_guard<std::mutex> lock(g_stateMutex);
		size_t n = 0;
		for (auto& d : g_donors)
			n += d.alive ? 1 : 0;
		return n;
	}

	// Called on g_queue for every peer that connects to the listener.
	void AcceptPeer(xpc_connection_t peer)
	{
		xpc_connection_set_target_queue(peer, g_queue);
		xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
			if (xpc_get_type(event) == XPC_TYPE_ERROR)
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				for (auto& donor : g_donors)
					if (donor.connection == peer)
						donor.alive = false;
				return;
			}
			if (xpc_get_type(event) != XPC_TYPE_DICTIONARY)
				return;
			const char* op = xpc_dictionary_get_string(event, ESP_DONOR_KEY_OP);
			if (!op || strcmp(op, ESP_DONOR_OP_HELLO) != 0)
				return;

			Donor donor;
			donor.connection = peer;
			donor.pid = xpc_dictionary_get_int64(event, ESP_DONOR_KEY_PID);
			donor.available = xpc_dictionary_get_uint64(event, ESP_DONOR_KEY_AVAILABLE);
			dispatch_semaphore_t semaphore;
			bool reused = false;
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				for (const auto& known : g_donors)
					reused = reused || (known.alive && known.pid == donor.pid);
				if (!reused)
					g_donors.push_back(donor);
				semaphore = g_helloSemaphore;
			}
			if (reused)
				SetStatus("iOS answered another donor request with process %lld that is already a donor; it is not counted", (long long)donor.pid);
			NSLog(@"[RamDonor] Donor pid %lld connected, %llu MB available%s", (long long)donor.pid, (unsigned long long)(donor.available >> 20), reused ? " (already known)" : "");
			if (semaphore)
				dispatch_semaphore_signal(semaphore);
		});
		xpc_connection_resume(peer);
	}

	NSXPCListenerEndpoint* MakeEndpoint()
	{
		if (!g_queue)
			g_queue = dispatch_queue_create("dev.espressu.ramdonor.host", DISPATCH_QUEUE_SERIAL);
		if (!g_listener)
		{
			g_listener = xpc_connection_create(nullptr, g_queue);
			xpc_connection_set_event_handler(g_listener, ^(xpc_object_t event) {
				if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
					AcceptPeer((xpc_connection_t)event);
			});
			xpc_connection_resume(g_listener);
		}
		xpc_endpoint_t raw = xpc_endpoint_create(g_listener);
		NSXPCListenerEndpoint* endpoint = [NSXPCListenerEndpoint new];
		if (!raw || ![endpoint respondsToSelector:@selector(_setEndpoint:)])
			return nil;
		[endpoint _setEndpoint:raw];
		return endpoint;
	}

	bool SpawnOneDonor(NSString* identifier, NSXPCListenerEndpoint* endpoint)
	{
		Class extensionClass = NSClassFromString(@"NSExtension");
		if (![extensionClass respondsToSelector:@selector(extensionWithIdentifier:error:)])
		{
			SetStatus("This iOS version can't start the donor extension");
			return false;
		}
		NSError* error = nil;
		id<ESPExtension> extension = [(Class<ESPExtension>)extensionClass extensionWithIdentifier:identifier error:&error];
		if (!extension)
		{
			SetStatus("Donor extension not found: %s", error.localizedDescription.UTF8String ?: identifier.UTF8String);
			return false;
		}
		[extension setRequestInterruptionBlock:^(NSUUID*) { SetStatus("A donor was interrupted by iOS"); }];
		[extension setRequestCancellationBlock:^(NSUUID*, NSError* cancelError) {
			SetStatus("Donor request cancelled: %s", cancelError.localizedDescription.UTF8String ?: "unknown");
		}];

		NSExtensionItem* item = [NSExtensionItem new];
		item.userInfo = @{ @ESP_DONOR_USERINFO_ENDPOINT : endpoint };

		__block NSUUID* requestId = nil;
		dispatch_semaphore_t began = dispatch_semaphore_create(0);
		[extension beginExtensionRequestWithInputItems:@[ item ] completion:^(NSUUID* identifier) {
			requestId = identifier;
			dispatch_semaphore_signal(began);
		}];
		dispatch_semaphore_wait(began, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpawnTimeoutSeconds * NSEC_PER_SEC)));
		if (!requestId)
		{
			SetStatus("iOS refused to start the donor extension");
			return false;
		}
		g_extensions.push_back(extension);
		g_requestIds.push_back(requestId);
		int pid = 0;
		if ([(id)extension respondsToSelector:@selector(pidForRequestIdentifier:)])
			pid = [extension pidForRequestIdentifier:requestId];
		SetStatus("Donor process spawned, pid %d (%llu MB free to this app at the time)", pid, (unsigned long long)(os_proc_available_memory() >> 20));
		return true;
	}

	// Starts one process per embedded donor extension copy until `wanted` distinct donors are connected.
	// Caller holds g_opMutex.
	void EnsureDonors(size_t wanted)
	{
		NSArray<NSString*>* identifiers = DonorIdentifiers();
		if (identifiers.count == 0)
		{
			SetStatus("No donor extension in PlugIns");
			return;
		}
		NSXPCListenerEndpoint* endpoint = nil;
		for (NSString* identifier in identifiers)
		{
			if (LiveDonorCount() >= wanted)
				return;
			const std::string key = identifier.UTF8String;
			if (g_startedIdentifiers.count(key))
				continue;
			g_startedIdentifiers.insert(key);
			if (!endpoint && !(endpoint = MakeEndpoint()))
			{
				SetStatus("Could not create the donor endpoint");
				return;
			}
			size_t before;
			dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				before = g_donors.size();
				g_helloSemaphore = semaphore;
			}
			if (!SpawnOneDonor(identifier, endpoint))
			{
				// iOS sometimes refuses a copy right after the previous one started: wait and retry once.
				[NSThread sleepForTimeInterval:1.5];
				if (!SpawnOneDonor(identifier, endpoint))
					continue; // try the next copy
			}
			dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpawnTimeoutSeconds * NSEC_PER_SEC)));
			bool connected;
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				connected = g_donors.size() > before;
			}
			if (!connected)
				SetStatus("A donor copy started but did not add a new process (reused or never connected)");
		}
	}

	void SendFree(const Donor& donor, uint64_t chunkId)
	{
		xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
		xpc_dictionary_set_string(request, ESP_DONOR_KEY_OP, ESP_DONOR_OP_FREE);
		xpc_dictionary_set_uint64(request, ESP_DONOR_KEY_ID, chunkId);
		xpc_connection_send_message(donor.connection, request);
	}

	// Asks one donor for up to `want` bytes and maps them at `target`. Returns bytes mapped.
	size_t MapFromDonor(size_t donorIndex, uintptr_t target, size_t want)
	{
		Donor donor;
		{
			std::lock_guard<std::mutex> lock(g_stateMutex);
			donor = g_donors[donorIndex];
		}

		xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
		xpc_dictionary_set_string(request, ESP_DONOR_KEY_OP, ESP_DONOR_OP_ALLOC);
		xpc_dictionary_set_uint64(request, ESP_DONOR_KEY_SIZE, want);
		const bool prefault = Prefault();
		const bool purgeable = Purgeable();
		xpc_dictionary_set_bool(request, ESP_DONOR_KEY_PREFAULT, prefault);
		xpc_dictionary_set_bool(request, ESP_DONOR_KEY_PURGEABLE, purgeable);

		// Runs on the emulator thread, never on the connection's own queue, so a synchronous wait is fine.
		xpc_object_t reply = xpc_connection_send_message_with_reply_sync(donor.connection, request);
		if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
		{
			SetStatus("A donor went away while asking for %zu MB", want >> 20);
			std::lock_guard<std::mutex> lock(g_stateMutex);
			g_donors[donorIndex].alive = false;
			return 0;
		}
		if (!xpc_dictionary_get_bool(reply, ESP_DONOR_KEY_OK))
		{
			SetStatus("Donor could not supply %zu MB: %s", want >> 20, xpc_dictionary_get_string(reply, ESP_DONOR_KEY_ERROR) ?: "unknown");
			return 0;
		}

		xpc_object_t shmem = xpc_dictionary_get_value(reply, ESP_DONOR_KEY_SHMEM);
		const uint64_t chunkId = xpc_dictionary_get_uint64(reply, ESP_DONOR_KEY_ID);
		const size_t granted = (size_t)xpc_dictionary_get_uint64(reply, ESP_DONOR_KEY_SIZE);
		if (!shmem)
		{
			SetStatus("A donor's reply carried no shared memory");
			SendFree(donor, chunkId);
			return 0;
		}

		// xpc_shmem_map places the region wherever it likes. vm_remap then moves it (sharing the same
		// pages, no copy) onto the exact guest address, and the temporary mapping is dropped.
		void* temporary = nullptr;
		const size_t mapped = xpc_shmem_map(shmem, &temporary);
		if (mapped == 0 || !temporary)
		{
			SetStatus("xpc_shmem_map failed");
			SendFree(donor, chunkId);
			return 0;
		}
		const size_t length = std::min({ mapped, granted, want });

		vm_address_t destination = (vm_address_t)target;
		vm_prot_t current = VM_PROT_NONE, maximum = VM_PROT_NONE;
		const kern_return_t kr = vm_remap(mach_task_self(), &destination, length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
		                                  mach_task_self(), (vm_address_t)temporary, FALSE, &current, &maximum, VM_INHERIT_NONE);
		vm_deallocate(mach_task_self(), (vm_address_t)temporary, mapped);
		if (kr != KERN_SUCCESS)
		{
			SetStatus("vm_remap failed: %s", mach_error_string(kr));
			SendFree(donor, chunkId);
			return 0;
		}
		vm_protect(mach_task_self(), destination, length, FALSE, VM_PROT_READ | VM_PROT_WRITE);

		g_chunks.push_back({ target, length, donorIndex, chunkId });
		g_donatedBytes += length;
		std::lock_guard<std::mutex> lock(g_stateMutex);
		g_donors[donorIndex].available = g_donors[donorIndex].available > length ? g_donors[donorIndex].available - length : 0;
		return length;
	}
}

namespace IOSRamDonor
{
	bool IsEnabled()
	{
		return UserEnabled() && DonorIdentifiers().count > 0;
	}

	size_t BackWithDonors(void* target, size_t size)
	{
		if (!IsEnabled() || !target || size < kMinRegionBytes)
			return 0;

		const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
		std::lock_guard<std::mutex> op(g_opMutex);
		EnsureDonors(MaxDonors());

		const size_t page = (size_t)vm_page_size;
		size &= ~(page - 1);
		size_t mappedTotal = 0;

		size_t donorCount;
		{
			std::lock_guard<std::mutex> lock(g_stateMutex);
			donorCount = g_donors.size();
		}
		for (size_t i = 0; i < donorCount && mappedTotal < size; ++i)
		{
			size_t available;
			{
				std::lock_guard<std::mutex> lock(g_stateMutex);
				available = g_donors[i].alive ? g_donors[i].available : 0;
			}
			const size_t want = std::min(size - mappedTotal, available & ~(page - 1));
			if (want == 0)
				continue;
			mappedTotal += MapFromDonor(i, (uintptr_t)target + mappedTotal, want);
		}

		const size_t live = LiveDonorCount();
		const double elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
		if (elapsedMs > 250.0)
			SetStatus("Backing %zu MB with donors took %.0f ms (the emulator waits for this)", size >> 20, elapsedMs);
		if (mappedTotal >= size)
			SetStatus("%zu MB of %zu MB mapped at %p across %zu donor(s)", mappedTotal >> 20, size >> 20, target, live);
		else
			SetStatus("%zu donor(s) could only take %zu MB of the %zu MB needed; the rest uses normal memory", live, mappedTotal >> 20, size >> 20);
		return mappedTotal;
	}

	void Release(void* target, size_t size)
	{
		const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
		const size_t donatedBefore = g_donatedBytes.load();
		std::lock_guard<std::mutex> op(g_opMutex);
		const uintptr_t begin = (uintptr_t)target;
		const uintptr_t end = begin + size;
		for (auto it = g_chunks.begin(); it != g_chunks.end();)
		{
			if (it->target < end && begin < it->target + it->length)
			{
				Donor donor;
				bool alive;
				{
					std::lock_guard<std::mutex> lock(g_stateMutex);
					donor = g_donors[it->donorIndex];
					alive = donor.alive;
					if (alive)
						g_donors[it->donorIndex].available += it->length;
				}
				if (alive)
					SendFree(donor, it->chunkId);
				g_donatedBytes -= it->length;
				it = g_chunks.erase(it);
			}
			else
				++it;
		}
		const size_t freed = donatedBefore > g_donatedBytes.load() ? donatedBefore - g_donatedBytes.load() : 0;
		if (freed > 0)
			SetStatus("Released %zu MB of donor memory (%.0f ms)", freed >> 20, (CFAbsoluteTimeGetCurrent() - started) * 1000.0);
	}

	void Shutdown()
	{
		std::lock_guard<std::mutex> op(g_opMutex);
		{
			std::lock_guard<std::mutex> lock(g_stateMutex);
			for (auto& donor : g_donors)
			{
				if (!donor.alive)
					continue;
				xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
				xpc_dictionary_set_string(request, ESP_DONOR_KEY_OP, ESP_DONOR_OP_QUIT);
				xpc_connection_send_message(donor.connection, request);
				donor.alive = false;
			}
			g_donors.clear();
		}
		for (size_t i = 0; i < g_extensions.size() && i < g_requestIds.size(); ++i)
			[g_extensions[i] cancelExtensionRequestWithIdentifier:g_requestIds[i]];
		g_extensions.clear();
		g_requestIds.clear();
		g_chunks.clear();
		g_donatedBytes = 0;
		g_donorFootprint = 0;
		g_startedIdentifiers.clear();
		if (g_listener)
		{
			xpc_connection_cancel(g_listener);
			g_listener = nullptr;
		}
		SetStatus("RAM donor: stopped");
	}

	void LiftOwnJetsamLimit()
	{
		const uint64_t before = (uint64_t)os_proc_available_memory() + OwnFootprintBytes();
		const int viaProperties = ESPSetMemlimitProperties(6144, false);
		const int viaTaskLimit = ESPLiftJetsamLimit(6144);
		const uint64_t after = (uint64_t)os_proc_available_memory() + OwnFootprintBytes();
		g_originalLimit = before;
		const auto word = [](int error) { return error == 0 ? "ok" : strerror(error); };
		g_limitLifted = (viaProperties == 0 || viaTaskLimit == 0);
		// A call that returns success is not proof: only a limit iOS reports as bigger counts.
		g_limitVerified = g_limitLifted && after > before + (256ull << 20);
		if (!g_limitLifted)
			SetStatus("Could not raise the app's memory limit (properties: %s, task limit: %s); needs the com.apple.private.memorystatus entitlement",
				word(viaProperties), word(viaTaskLimit));
		else if (g_limitVerified)
			SetStatus("Memory limit raised from %llu MB to %llu MB (properties: %s, task limit: %s); the app and its donors budget up to %llu MB in total",
				(unsigned long long)(before >> 20), (unsigned long long)(after >> 20), word(viaProperties), word(viaTaskLimit),
				(unsigned long long)(MemoryCapBytes() >> 20));
		else
			SetStatus("iOS accepted the memory limit change (properties: %s, task limit: %s) but still reports a %llu MB limit, so the app stays inside that",
				word(viaProperties), word(viaTaskLimit), (unsigned long long)(after >> 20));
	}

	// Asks every donor for its own footprint without blocking the caller; the replies update the cached total.
	void RefreshDonorFootprintsIfStale()
	{
		const double now = CFAbsoluteTimeGetCurrent();
		double last = g_footprintRefreshedAt.load();
		if (now - last < 1.0 || !g_footprintRefreshedAt.compare_exchange_strong(last, now))
			return;
		std::vector<xpc_connection_t> connections;
		{
			std::lock_guard<std::mutex> lock(g_stateMutex);
			for (const auto& donor : g_donors)
				if (donor.alive && donor.connection)
					connections.push_back(donor.connection);
		}
		for (xpc_connection_t connection : connections)
		{
			xpc_object_t request = xpc_dictionary_create(nullptr, nullptr, 0);
			xpc_dictionary_set_string(request, ESP_DONOR_KEY_OP, ESP_DONOR_OP_STATUS);
			xpc_connection_send_message_with_reply(connection, request, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t reply) {
				if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
					return;
				const int64_t pid = xpc_dictionary_get_int64(reply, ESP_DONOR_KEY_PID);
				const uint64_t footprint = xpc_dictionary_get_uint64(reply, ESP_DONOR_KEY_FOOTPRINT);
				std::lock_guard<std::mutex> lock(g_stateMutex);
				uint64_t total = 0;
				for (auto& donor : g_donors)
				{
					if (donor.pid == pid)
						donor.footprint = footprint;
					if (donor.alive)
						total += donor.footprint;
				}
				g_donorFootprint = total;
			});
		}
	}

	uint64_t AvailableMemory()
	{
		const uint64_t raw = (uint64_t)os_proc_available_memory();
		// Unless iOS really reports a bigger limit, what it reports is what it enforces: a run that trusted
		// a 3 GB budget was killed at the stock 2.3 GB limit ("per-process-limit").
		if (!g_limitVerified.load(std::memory_order_relaxed))
			return raw;
		const uint64_t footprint = OwnFootprintBytes();
		// The ceiling covers this app plus its donors. What the donors themselves report holding is added;
		// pages that iOS charges to this app instead are already in `footprint`, so nothing is counted twice.
		RefreshDonorFootprintsIfStale();
		const uint64_t total = footprint + g_donorFootprint.load();
		const uint64_t cap = MemoryCapBytes();
		return total < cap ? cap - total : 1;
	}

	size_t DonatedBytes()
	{
		return g_donatedBytes.load();
	}

	size_t DonorFootprintBytes()
	{
		return (size_t)g_donorFootprint.load();
	}

	size_t LiveDonors()
	{
		return LiveDonorCount();
	}

	const char* StatusLine()
	{
		static thread_local std::string copy;
		std::lock_guard<std::mutex> lock(g_stateMutex);
		copy = g_status;
		return copy.c_str();
	}
}
