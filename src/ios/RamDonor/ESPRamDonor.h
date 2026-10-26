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

#define ESP_DONOR_KEY_OP        "op"
#define ESP_DONOR_KEY_PID       "pid"
#define ESP_DONOR_KEY_AVAILABLE "available"
#define ESP_DONOR_KEY_SIZE      "size"
#define ESP_DONOR_KEY_ID        "id"
#define ESP_DONOR_KEY_OK        "ok"
#define ESP_DONOR_KEY_SHMEM     "shmem"
#define ESP_DONOR_KEY_ERROR     "error"
#define ESP_DONOR_KEY_PREFAULT  "prefault"

#define ESP_DONOR_OP_HELLO "hello"
#define ESP_DONOR_OP_ALLOC "alloc"
#define ESP_DONOR_OP_FREE  "free"
#define ESP_DONOR_OP_QUIT  "quit"

// NSExtensionItem.userInfo key that carries the host's NSXPCListenerEndpoint.
#define ESP_DONOR_USERINFO_ENDPOINT "endpoint"  // use as @ESP_DONOR_USERINFO_ENDPOINT in Objective-C
