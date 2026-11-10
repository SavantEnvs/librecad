// libFuzzer entry point: read a DXF with dxfRW::read, keep what the reader returned (layers, LINE and TEXT
// entities with their extended data, the declared $DWGCODEPAGE) and save it again as R12/R2000/R2004 ASCII DXF,
// as an application that opens and saves a drawing does. The reader hands some strings back as the bytes of
// the file (extended data), which the writer then encodes through the codepage codec.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include <unistd.h>

#include "drw_entities.h"
#include "fuzz_null_interface.h"
#include "libdxfrw.h"

namespace {

class RoundTripInterface : public FuzzNullInterface {
public:
    dxfRW *writer{nullptr};
    std::string codePage;
    std::vector<DRW_Layer> layers;
    std::vector<DRW_Line> lines;
    std::vector<DRW_Text> texts;

    void addHeader(const DRW_Header *h) override {
        if (!h)
            return;
        const auto it = h->vars.find("$DWGCODEPAGE");
        if (it != h->vars.end() && it->second && it->second->type() == DRW_Variant::STRING
            && it->second->content.s)
            codePage = *it->second->content.s;
    }
    void addLayer(const DRW_Layer &l) override {
        if (layers.size() < 64)
            layers.push_back(l);
    }
    void addLine(const DRW_Line &l) override {
        if (lines.size() < 64)
            lines.push_back(l);
    }
    void addText(const DRW_Text &t) override {
        if (texts.size() < 64)
            texts.push_back(t);
    }

    void writeHeader(DRW_Header &h) override {
        if (!codePage.empty())
            h.addStr("$DWGCODEPAGE", codePage, 3);
    }
    void writeLayers() override {
        for (auto &l : layers)
            (void)writer->writeLayer(&l);
    }
    void writeEntities() override {
        for (auto &l : lines)
            (void)writer->writeLine(&l);
        for (auto &t : texts)
            (void)writer->writeText(&t);
    }
};

} // namespace

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t *data, std::size_t size) {
    const char *dir = std::getenv("TMPDIR");
    std::string in = std::string(dir && *dir ? dir : "/tmp") + "/fuzz_rt_in_XXXXXX";
    const int fd = mkstemp(&in[0]);
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
        RoundTripInterface iface;
        {
            dxfRW rw(in.c_str());
            if (!rw.read(&iface, /*ext=*/false))
                ok = false;
        }
        if (ok) {
            const std::string out = in + ".out";
            for (DRW::Version v : {DRW::AC1009, DRW::AC1015, DRW::AC1018}) {
                dxfRW rw(out.c_str());
                iface.writer = &rw;
                (void)rw.write(&iface, v, /*binary=*/false);
            }
            std::remove(out.c_str());
        }
    }
    std::remove(in.c_str());
    return 0;
}
