// ATEM Switchers SDK の C の窓口 (ATEMBridge.h を参照)

#include "ATEMBridge.h"
#include "BMDSwitcherAPI.h"
#include <atomic>
#include <string>
#include <vector>

namespace {

std::string toString(CFStringRef s) {
    if (!s) return "";
    char buf[256] = {0};
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    return buf;
}

void copyOut(const std::string &s, char *buf, int len) {
    if (len <= 0) return;
    snprintf(buf, len, "%s", s.c_str());
}

/// 切れたことを知るための受け口
class SwitcherCallback : public IBMDSwitcherCallback {
public:
    std::atomic<bool> disconnected{false};
    HRESULT QueryInterface(REFIID, LPVOID *ppv) override { *ppv = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override {
        ULONG r = --refs;
        if (r == 0) delete this;
        return r;
    }
    HRESULT Notify(BMDSwitcherEventType eventType, BMDSwitcherVideoMode) override {
        if (eventType == bmdSwitcherEventTypeDisconnected) disconnected = true;
        return S_OK;
    }
private:
    std::atomic<ULONG> refs{1};
};

struct Input { int64_t id; std::string name; };

} // namespace

struct ATEMSDK {
    IBMDSwitcher *switcher = nullptr;
    IBMDSwitcherMixEffectBlock *me = nullptr;
    SwitcherCallback *callback = nullptr;
    std::vector<Input> inputs;
};

extern "C" {

int atem_sdk_available(void) {
    IBMDSwitcherDiscovery *d = CreateBMDSwitcherDiscoveryInstance();
    if (!d) return 0;
    d->Release();
    return 1;
}

ATEMSDK *atem_sdk_connect(const char *address, int32_t *failReason) {
    IBMDSwitcherDiscovery *d = CreateBMDSwitcherDiscoveryInstance();
    if (!d) return nullptr;
    CFStringRef addr = CFStringCreateWithCString(kCFAllocatorDefault, address ? address : "", kCFStringEncodingUTF8);
    IBMDSwitcher *sw = nullptr;
    BMDSwitcherConnectToFailure fail = (BMDSwitcherConnectToFailure)0;
    HRESULT hr = d->ConnectTo(addr, &sw, &fail);
    CFRelease(addr);
    d->Release();
    if (hr != S_OK || !sw) {
        if (failReason) *failReason = (int32_t)fail;
        return nullptr;
    }
    ATEMSDK *s = new ATEMSDK();
    s->switcher = sw;
    s->callback = new SwitcherCallback();
    sw->AddCallback(s->callback);

    // 最初の M/E (ATEM Mini は 1 つだけ)
    IBMDSwitcherMixEffectBlockIterator *mit = nullptr;
    if (sw->CreateIterator(IID_IBMDSwitcherMixEffectBlockIterator, (LPVOID *)&mit) == S_OK && mit) {
        mit->Next(&s->me);
        mit->Release();
    }
    // 外部の入力 (HDMI / SDI)
    IBMDSwitcherInputIterator *iit = nullptr;
    if (sw->CreateIterator(IID_IBMDSwitcherInputIterator, (LPVOID *)&iit) == S_OK && iit) {
        IBMDSwitcherInput *in = nullptr;
        while (iit->Next(&in) == S_OK && in) {
            BMDSwitcherPortType type;
            BMDSwitcherInputId id;
            if (in->GetPortType(&type) == S_OK && type == bmdSwitcherPortTypeExternal &&
                in->GetInputId(&id) == S_OK) {
                CFStringRef name = nullptr;
                in->GetLongName(&name);
                std::string n = toString(name);
                if (name) CFRelease(name);
                s->inputs.push_back({id, n.empty() ? std::to_string(id) : n});
            }
            in->Release();
            in = nullptr;
        }
        iit->Release();
    }
    return s;
}

void atem_sdk_release(ATEMSDK *s) {
    if (!s) return;
    if (s->me) s->me->Release();
    if (s->switcher) {
        s->switcher->RemoveCallback(s->callback);
        s->switcher->Release();
    }
    if (s->callback) s->callback->Release();
    delete s;
}

int atem_sdk_is_connected(ATEMSDK *s) { return s && !s->callback->disconnected; }

void atem_sdk_product_name(ATEMSDK *s, char *buf, int len) {
    CFStringRef name = nullptr;
    if (s && s->switcher->GetProductName(&name) == S_OK) {
        copyOut(toString(name), buf, len);
        if (name) CFRelease(name);
    } else {
        copyOut("", buf, len);
    }
}

int atem_sdk_input_count(ATEMSDK *s) { return s ? (int)s->inputs.size() : 0; }
int64_t atem_sdk_input_id(ATEMSDK *s, int i) { return s->inputs.at(i).id; }
void atem_sdk_input_name(ATEMSDK *s, int i, char *buf, int len) { copyOut(s->inputs.at(i).name, buf, len); }

int64_t atem_sdk_program(ATEMSDK *s) {
    BMDSwitcherInputId v;
    return (s && s->me && s->me->GetProgramInput(&v) == S_OK) ? v : -1;
}
int atem_sdk_set_program(ATEMSDK *s, int64_t input) { return s && s->me && s->me->SetProgramInput(input) == S_OK; }
int atem_sdk_set_preview(ATEMSDK *s, int64_t input) { return s && s->me && s->me->SetPreviewInput(input) == S_OK; }
int atem_sdk_auto(ATEMSDK *s) { return s && s->me && s->me->PerformAutoTransition() == S_OK; }

} // extern "C"
