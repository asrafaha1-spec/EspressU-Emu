// SPDX-License-Identifier: MPL-2.0
//
// RAM limit workaround: back guest memory with memory that lives in app-extension processes.
//
// iOS applies a memory limit to every process. EspressU ships a tiny extension (EspressURamDonor.appex);
// the host starts a few copies of it, each allocates memory in its own process and shares it back as an
// xpc_shmem object, and the host remaps that memory over the guest address space.
//
// All entry points are safe to call when the feature is off or the extension is missing: they simply
// report that nothing was mapped and the caller keeps using ordinary anonymous memory.

#pragma once

#include <cstddef>
#include <cstdint>

namespace IOSRamDonor
{
	// Only ranges at least this large are worth donating (the guest MEM2 area is the real target).
	constexpr size_t kMinRegionBytes = 128ull * 1024 * 1024;

	// True when the user setting is on and the extension is present in the app bundle.
	bool IsEnabled();

	// Replaces the start of [target, target + size) with donor memory and returns how many bytes were
	// replaced (page aligned, possibly 0). `target` must lie inside a region this process already owns.
	// The rest of the range keeps its ordinary memory, so a partial result is still usable.
	size_t BackWithDonors(void* target, size_t size);

	// Forgets (and asks donors to free) every donated chunk that overlaps the range. Call after the range's
	// mapping has been replaced or dropped.
	void Release(void* target, size_t size);

	// Stops every donor process. Called at emulator shutdown.
	void Shutdown();

	// Cheap, non-blocking counters for the periodic memory log line.
	size_t DonatedBytes();
	size_t LiveDonors();

	// Human readable one-line state for logs and the diagnostics screen.
	const char* StatusLine();
}
