// Diagnostic probe: logs at dylib-load time, before TVExtensionMain runs.
// The extension process was exiting (code 3) within ~60ms of launch without
// emitting a single log line — this pins down whether execution even reaches
// userspace code. Remove once the Top Shelf lifecycle is confirmed healthy.
#include <os/log.h>

__attribute__((constructor))
static void cinemax_topshelf_boot(void) {
    os_log(os_log_create("com.cinemax", "TopShelf"), "TopShelf > binary loaded (C constructor)");
}
