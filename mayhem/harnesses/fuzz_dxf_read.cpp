// libFuzzer entry point on dxfRW::read (ASCII/binary DXF). Derived from
// libraries/libdxfrw/tests/fuzz/fuzz_dxf_read.cpp; scratch file goes under $TMPDIR.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include <unistd.h>

#include "fuzz_null_interface.h"
#include "libdxfrw.h"

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    const char *dir = std::getenv("TMPDIR");
    std::string path = std::string(dir && *dir ? dir : "/tmp") + "/fuzz_dxf_XXXXXX";
    const int fd = mkstemp(&path[0]);
    if (fd < 0)
        return 0;
    std::size_t written = 0;
    bool ok = true;
    while (written < size) {
        const ssize_t n = ::write(fd, data + written, size - written);
        if (n <= 0) { ok = false; break; }
        written += static_cast<std::size_t>(n);
    }
    ::close(fd);
    if (ok) {
        dxfRW rw(path.c_str());
        FuzzNullInterface iface;
        (void)rw.read(&iface, /*ext=*/false);
    }
    std::remove(path.c_str());
    return 0;
}
