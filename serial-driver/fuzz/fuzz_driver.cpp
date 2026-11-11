// SPDX-License-Identifier: CC0-1.0
// Fuzz harness for the DriverKit serial driver, for Linux.
//
// The real driver sources (../Driver/*.cpp) are compiled against the fake
// DriverKit in shim/. This file implements that fake and plays three roles,
// all steered by the fuzzer input:
//   * the kernel side of IOUserSerial: open, close, activate, ring buffers;
//   * the USB device: descriptors, transfer completions, errors, unplug;
//   * failure injection: any framework call that can fail may fail.
//
// Besides the sanitizers, it checks that bytes are not lost, repeated or
// invented in either direction, that the driver never stops transferring
// while a client has the port open, and that every object is released.
//
// Byte 0 bit 0 selects the mode. "Strict" only makes call sequences a sane
// kernel would make. "Loose" also makes hostile ones (bad queue sizes,
// corrupt ring indices, calls in any order); there only memory safety and
// leaks are worth reporting.
//
// Bit 3 lets completions of aborted transfers arrive late (see run_operation).
//
// Set FUZZ_TRACE=1 to print the calls made for one input.
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fuzzer/FuzzedDataProvider.h>

#include "QuectelSerialInterface.h"
#include "QuectelSerialPort.h"

using driverkit::serial::SerialPortInterface;

namespace {

const uint32_t kMaxMemory = 1u << 16;

struct World {
    bool strict = true;
    bool late = false;            // completions of aborted transfers may be delayed
    int create_mode = 0;          // 0: port not started, 1: started by Create, 2: wrong class
    uint8_t fail_at[3] = {0, 0, 0};
    unsigned calls = 0;           // counts framework calls that can fail
    std::vector<uint8_t> descriptor;

    IOUSBHostInterface *usb = nullptr;
    QuectelSerialInterface *iface = nullptr;
    QuectelSerialPort *port = nullptr;
    IOUSBHostPipe *in_pipe = nullptr, *out_pipe = nullptr;
    int open_count = 0;
    bool iface_stopped = false, port_started = false, port_stopped = false;

    // Kernel's view of the port.
    bool connected = false, active = false, kicked = false, corrupt = false;
    unsigned rx_faults = 0;
    IOBufferMemoryDescriptor *if_memory = nullptr;
    IOMemoryDescriptor *rx_memory = nullptr, *tx_memory = nullptr;
    SerialPortInterface *queue = nullptr;
    uint8_t *rx = nullptr, *tx = nullptr;
    uint32_t rx_size = 0, tx_size = 0;
    std::vector<uint8_t> written;  // every byte the client wrote, by txPI
    bool rx_overrun = false;

    // Parameters for the next ConnectQueues.
    uint32_t rx_log = 6, tx_log = 6, rx_offset = 0, tx_offset = 0;
    uint32_t short_by = 0;
    int null_output = 0;
    bool short_interface = false;
};

World *W = nullptr;
int live_objects = 0;
const bool tracing = getenv("FUZZ_TRACE") != nullptr;

void trace(const char *format, ...) __attribute__((format(printf, 1, 2)));
void trace(const char *format, ...) {
    if (!tracing) return;
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
    fputc('\n', stderr);
}

[[noreturn]] void fail(const char *message) {
    fprintf(stderr, "\nFINDING (%s mode): %s\n",
            !W || !W->strict ? "loose" : W->late ? "strict, late completions" : "strict", message);
    abort();
}

// Data integrity and "keeps transferring" checks. They only mean something
// when the kernel behaves, so they are off in loose mode.
void expect(bool condition, const char *message) {
    if (!condition && W->strict) fail(message);
}

// True when this framework call should fail (chosen by the input).
bool inject(const char *what) {
    const unsigned index = ++W->calls;
    for (auto wanted : W->fail_at) {
        if (wanted != 0 && wanted == index) { trace("    [%s fails]", what); return true; }
    }
    return false;
}

void drop_queues() {
    OSSafeReleaseNULL(W->if_memory);
    OSSafeReleaseNULL(W->rx_memory);
    OSSafeReleaseNULL(W->tx_memory);
    W->queue = nullptr;
    W->rx = W->tx = nullptr;
    W->connected = W->active = W->kicked = false;
}

IOMemoryDescriptor *make_memory(uint64_t length, bool buffer, bool read_only = false) {
    IOMemoryDescriptor *memory = buffer ? new IOBufferMemoryDescriptor : new IOMemoryDescriptor;
    memory->length = length;
    if (!read_only) {
        memory->data = static_cast<uint8_t *>(calloc(1, length ? length : 1));
        return memory;
    }
    // Whole pages that the driver can read but not write: a write is a crash
    // here, as it is in a real driver extension.
    const size_t size = ((length ? length : 1) + 0xffff) & ~size_t(0xffff);
    void *pages = mmap(nullptr, size, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (pages == MAP_FAILED) fail("mmap failed");
    memory->data = static_cast<uint8_t *>(pages);
    memory->mapped = size;
    return memory;
}

}  // namespace

// ---------------------------------------------------------------- the fake

void os_log(int, const char *, ...) {}

OSObject::OSObject() { ++live_objects; }
OSObject::~OSObject() { --live_objects; }
void OSObject::retain() {
    if (refs <= 0) fail("retain of a freed object");
    ++refs;
}
void OSObject::release() {
    if (refs <= 0) fail("release of a freed object");
    if (--refs == 0) free();
}

kern_return_t IOMemoryDescriptor::CreateMapping(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
        IOMemoryMap **map) {
    if (inject("CreateMapping")) return kIOReturnNoMemory;
    auto result = new IOMemoryMap;
    retain();
    result->memory = this;
    *map = result;
    return kIOReturnSuccess;
}

kern_return_t IOBufferMemoryDescriptor::SetLength(uint64_t) {
    return inject("SetLength") ? kIOReturnError : kIOReturnSuccess;
}

kern_return_t IOBufferMemoryDescriptor::GetAddressRange(IOAddressSegment *range) {
    if (inject("GetAddressRange")) return kIOReturnError;
    range->address = reinterpret_cast<uint64_t>(data);
    range->length = length;
    return kIOReturnSuccess;
}

kern_return_t IOService::Start(IOService *, void *) {
    return inject("super::Start") ? kIOReturnError : kIOReturnSuccess;
}
kern_return_t IOService::Stop(IOService *, void *) { return kIOReturnSuccess; }
kern_return_t IOService::RegisterService() {
    return inject("RegisterService") ? kIOReturnError : kIOReturnSuccess;
}
kern_return_t IOService::Terminate(uint64_t) { return kIOReturnSuccess; }
kern_return_t IOService::CopyDispatchQueue(const char *, IODispatchQueue **queue) {
    if (inject("CopyDispatchQueue")) return kIOReturnError;
    *queue = new IODispatchQueue;
    return kIOReturnSuccess;
}
kern_return_t IOService::SetDispatchQueue(const char *, IODispatchQueue *) {
    return inject("SetDispatchQueue") ? kIOReturnError : kIOReturnSuccess;
}
kern_return_t IOService::SetProperties(OSDictionary *) {
    return inject("SetProperties") ? kIOReturnError : kIOReturnSuccess;
}

kern_return_t IOService::Create(IOService *provider, const char *, IOService **result) {
    if (inject("Create")) return kIOReturnError;
    if (W->create_mode == 2) { *result = new IOService; return kIOReturnSuccess; }
    auto port = new QuectelSerialPort;
    if (!port->init()) { port->release(); return kIOReturnNoMemory; }
    if (W->create_mode == 1 && port->Start(provider) != kIOReturnSuccess) {
        port->release();
        return kIOReturnError;
    }
    port->retain();  // the kernel's own reference
    W->port = port;
    *result = port;
    return kIOReturnSuccess;
}

kern_return_t QuectelSerialInterface::CreateActionReceiveComplete(size_t, OSAction **action) {
    if (inject("CreateAction")) return kIOReturnNoMemory;
    *action = new OSAction;
    return kIOReturnSuccess;
}
kern_return_t QuectelSerialInterface::CreateActionTransmitComplete(size_t, OSAction **action) {
    if (inject("CreateAction")) return kIOReturnNoMemory;
    *action = new OSAction;
    (*action)->kind = 1;
    return kIOReturnSuccess;
}

kern_return_t IOUSBHostInterface::Open(IOService *, uint32_t, void *) {
    if (inject("Open")) return kIOReturnError;
    ++W->open_count;
    return kIOReturnSuccess;
}
kern_return_t IOUSBHostInterface::Close(IOService *, uint32_t) {
    if (W->open_count <= 0) fail("USB interface closed more often than opened");
    --W->open_count;
    return kIOReturnSuccess;
}

const IOUSBConfigurationDescriptor *IOUSBHostInterface::CopyConfigurationDescriptor() {
    if (inject("CopyConfigurationDescriptor")) return nullptr;
    auto copy = malloc(W->descriptor.size());
    memcpy(copy, W->descriptor.data(), W->descriptor.size());
    return static_cast<const IOUSBConfigurationDescriptor *>(copy);
}
void IOUSBHostFreeDescriptor(const void *descriptor) { free(const_cast<void *>(descriptor)); }

// The input builds a well-formed descriptor chain (the host controller
// driver validates lengths before a driver sees them), so these two only
// walk it.
const IOUSBInterfaceDescriptor *IOUSBHostInterface::GetInterfaceDescriptor(
        const IOUSBConfigurationDescriptor *configuration) {
    if (inject("GetInterfaceDescriptor")) return nullptr;
    auto bytes = reinterpret_cast<const uint8_t *>(configuration);
    for (size_t at = bytes[0]; at + 2 <= W->descriptor.size(); at += bytes[at]) {
        if (bytes[at + 1] == 4)
            return reinterpret_cast<const IOUSBInterfaceDescriptor *>(bytes + at);
    }
    return nullptr;
}
const IOUSBEndpointDescriptor *IOUSBGetNextEndpointDescriptor(
        const IOUSBConfigurationDescriptor *configuration,
        const IOUSBInterfaceDescriptor *interface, const IOUSBDescriptorHeader *current) {
    auto bytes = reinterpret_cast<const uint8_t *>(configuration);
    auto from = reinterpret_cast<const uint8_t *>(current ? static_cast<const void *>(current)
                                                          : static_cast<const void *>(interface));
    for (size_t at = size_t(from - bytes) + from[0]; at + 2 <= W->descriptor.size();
         at += bytes[at]) {
        if (bytes[at + 1] == 4) return nullptr;
        if (bytes[at + 1] == 5)
            return reinterpret_cast<const IOUSBEndpointDescriptor *>(bytes + at);
    }
    return nullptr;
}

kern_return_t IOUSBHostInterface::CopyPipe(uint8_t address, IOUSBHostPipe **pipe) {
    if (inject("CopyPipe")) return kIOReturnError;
    auto result = new IOUSBHostPipe;
    result->address = address;
    auto &slot = (address & 0x80) ? W->in_pipe : W->out_pipe;
    if (slot == nullptr) { result->retain(); slot = result; }
    *pipe = result;
    return kIOReturnSuccess;
}

// Seen on macOS 27: a buffer created with only kIOMemoryDirectionOut is mapped
// read-only in the driver, so filling it for a transmit crashes.
kern_return_t IOUSBHostInterface::CreateIOBuffer(uint64_t options, uint64_t capacity,
        IOBufferMemoryDescriptor **buffer) {
    if (inject("CreateIOBuffer")) return kIOReturnNoMemory;
    *buffer = static_cast<IOBufferMemoryDescriptor *>(make_memory(capacity, true,
        options == kIOMemoryDirectionOut));
    return kIOReturnSuccess;
}

kern_return_t IOUSBHostInterface::DeviceRequest(uint8_t, uint8_t, uint16_t, uint16_t, uint16_t,
        IOMemoryDescriptor *, uint16_t *, uint32_t) {
    if (W->open_count <= 0) fail("control request on a closed USB interface");
    return inject("DeviceRequest") ? kIOUSBPipeStalled : kIOReturnSuccess;
}

kern_return_t IOUSBHostPipe::AsyncIO(IOMemoryDescriptor *memory, uint32_t length,
        OSAction *completion, uint32_t) {
    const bool in = (address & 0x80) != 0;
    if (memory == nullptr || completion == nullptr) fail("AsyncIO with a null argument");
    if (length == 0 || length > memory->length) fail("AsyncIO longer than its buffer");
    if (pending) fail("AsyncIO while the previous transfer on that pipe is not complete");
    if (W->iface_stopped) fail("AsyncIO after the interface was stopped");
    if (in && length % 64 != 0) fail("bulk IN request is not a multiple of the packet size");
    if (!in && W->queue != nullptr && !W->corrupt) {
        const uint32_t consumer = W->queue->txCI;
        if (length > W->queue->txPI - consumer) fail("transmits more bytes than the client wrote");
        for (uint32_t index = 0; index < length; ++index) {
            if (memory->data[index] != W->written[consumer + index])
                fail("transmitted bytes differ from what the client wrote");
        }
    }
    if (inject(in ? "AsyncIO in" : "AsyncIO out")) {
        if (in) ++W->rx_faults;
        return kIOReturnNotResponding;
    }
    trace("    AsyncIO %s %u", in ? "in" : "out", length);
    memory->retain();
    completion->retain();
    buffer = memory;
    action = completion;
    pending_length = length;
    pending = true;
    aborted = false;
    return kIOReturnSuccess;
}

kern_return_t IOUSBHostPipe::Abort(uint32_t, kern_return_t, IOService *) {
    if (pending) aborted = true;
    return kIOReturnSuccess;
}
kern_return_t IOUSBHostPipe::ClearStall(bool) { return kIOReturnSuccess; }

kern_return_t IOUserSerial::ConnectQueues(IOBufferMemoryDescriptor **ifmd,
        IOMemoryDescriptor **rxqmd, IOMemoryDescriptor **txqmd, IOMemoryDescriptor *,
        IOMemoryDescriptor *, uint32_t, uint32_t, uint8_t, uint8_t, void *) {
    drop_queues();
    if (inject("super::ConnectQueues")) return kIOReturnNoMemory;
    const uint64_t rx_size = W->rx_log < 32 ? uint64_t(1) << W->rx_log : 0;
    const uint64_t tx_size = W->tx_log < 32 ? uint64_t(1) << W->tx_log : 0;
    auto length = [](uint64_t wanted) {
        if (wanted > kMaxMemory) wanted = kMaxMemory;
        return wanted > W->short_by ? wanted - W->short_by : 0;
    };
    W->if_memory = static_cast<IOBufferMemoryDescriptor *>(make_memory(
        W->short_interface ? sizeof(SerialPortInterface) - 1 : sizeof(SerialPortInterface), true));
    W->rx_memory = make_memory(length(W->rx_offset + rx_size), false);
    W->tx_memory = make_memory(length(W->tx_offset + tx_size), false);
    if (!W->short_interface) {
        W->queue = reinterpret_cast<SerialPortInterface *>(W->if_memory->data);
        W->queue->rxqlogsz = W->rx_log;
        W->queue->txqlogsz = W->tx_log;
        W->queue->rxqoffset = W->rx_offset;
        W->queue->txqoffset = W->tx_offset;
    }
    W->rx = W->rx_memory->data + W->rx_offset;
    W->tx = W->tx_memory->data + W->tx_offset;
    W->rx_size = uint32_t(rx_size);
    W->tx_size = uint32_t(tx_size);
    W->written.clear();
    W->corrupt = false;
    // Out parameters carry a reference that the caller (the kernel glue,
    // here the harness) drops again.
    if (W->null_output != 1) { W->if_memory->retain(); *ifmd = W->if_memory; }
    if (W->null_output != 2) { W->rx_memory->retain(); *rxqmd = W->rx_memory; }
    if (W->null_output != 3) { W->tx_memory->retain(); *txqmd = W->tx_memory; }
    return kIOReturnSuccess;
}

kern_return_t IOUserSerial::DisconnectQueues(void *) {
    drop_queues();
    return kIOReturnSuccess;
}

void IOUserSerial::RxDataAvailable() {}
void IOUserSerial::TxFreeSpaceAvailable() {}
kern_return_t IOUserSerial::RxError(bool overrun, bool, bool, bool) {
    if (overrun) W->rx_overrun = true;
    return kIOReturnSuccess;
}

// ------------------------------------------------------------- the harness

namespace {

bool port_usable() { return W->port != nullptr && W->port_started && !W->port_stopped; }

void complete(IOUSBHostPipe *pipe, IOReturn status, uint32_t count) {
    auto action = pipe->action;
    pipe->buffer->release();
    pipe->buffer = nullptr;
    pipe->action = nullptr;
    pipe->pending = pipe->aborted = false;
    if (pipe->address & 0x80) W->iface->ReceiveComplete_Impl(action, status, count, 0);
    else W->iface->TransmitComplete_Impl(action, status, count, 0);
    action->release();
}

void complete_receive(IOReturn status, uint32_t count, uint8_t seed) {
    auto pipe = W->in_pipe;
    const uint32_t filled = count < pipe->pending_length ? count : pipe->pending_length;
    std::vector<uint8_t> data(filled);
    for (uint32_t index = 0; index < filled; ++index) data[index] = uint8_t(seed + index * 7);
    if (filled) memcpy(pipe->buffer->data, data.data(), filled);
    if (status != kIOReturnSuccess && status != kIOReturnAborted) ++W->rx_faults;

    const bool check = W->queue != nullptr && !W->corrupt;
    const uint32_t producer = check ? W->queue->rxPI : 0;
    const uint32_t space = check ? W->rx_size - 1 - (producer - W->queue->rxCI) : 0;
    W->rx_overrun = false;
    trace("  receive complete status 0x%x count %u", unsigned(status), count);
    complete(pipe, status, count);
    if (!check || W->queue == nullptr) return;

    const uint32_t stored = W->queue->rxPI - producer;
    const bool deliver = status == kIOReturnSuccess && W->active && !W->iface_stopped
        && port_usable();
    const uint32_t expected = !deliver ? 0 : (filled < space ? filled : space);
    expect(!(stored > expected), "received bytes stored that should not have been");
    expect(!(stored < expected), "received bytes lost while the client had room for them");
    for (uint32_t index = 0; index < stored; ++index) {
        if (W->rx[(producer + index) & (W->rx_size - 1)] != data[index])
            fail("received bytes stored in the ring differ from what the modem sent");
    }
    expect(!(deliver && filled > space && !W->rx_overrun),
           "received bytes dropped without reporting an overrun");
}

void flush_aborted() {
    for (auto pipe : {W->in_pipe, W->out_pipe}) {
        if (pipe == nullptr || !pipe->pending || !pipe->aborted) continue;
        if (pipe->address & 0x80) complete_receive(kIOReturnAborted, 0, 0);
        else { trace("  transmit complete (aborted)"); complete(pipe, kIOReturnAborted, 0); }
    }
}

void stop_port() {
    trace("  port Stop");
    W->port->Stop(W->iface);
    W->port_stopped = true;
    drop_queues();
}

void stop_interface() {
    trace("  interface Stop");
    W->iface->Stop(W->usb);
    W->iface_stopped = true;
}

void check_invariants() {
    if (W->queue == nullptr || W->corrupt) return;
    const auto queue = W->queue;
    if (queue->txPI - queue->txCI >= W->tx_size) fail("txCI moved past txPI");
    if (queue->rxPI - queue->rxCI >= W->rx_size) fail("rxPI moved past the reader");
    if (!W->active || W->iface_stopped || !port_usable()) return;
    expect(!(W->kicked && queue->txPI != queue->txCI && !W->out_pipe->pending),
           "client data is waiting but nothing is being transmitted");
    expect(!(W->rx_faults == 0 && !W->in_pipe->pending),
           "port is open but no receive request is pending");
}

void connect(FuzzedDataProvider &input) {
    const uint8_t shape = input.ConsumeIntegral<uint8_t>();
    static const uint32_t sizes[] = {4, 6, 12, 13};  // around the 4096 byte USB buffer
    W->rx_log = sizes[shape & 3];
    W->tx_log = sizes[(shape >> 2) & 3];
    W->rx_offset = W->tx_offset = W->short_by = 0;
    W->null_output = 0;
    W->short_interface = false;
    if (!W->strict && (shape & 0xf0) != 0) {
        static const uint32_t logs[] = {0, 1, 13, 16, 17, 30, 31, 32, 255};
        static const uint32_t offsets[] = {0, 1, 64, 4096, 65535, 65536, 0x7fffffff, 0xffffffff};
        const uint8_t more = input.ConsumeIntegral<uint8_t>();
        switch (shape >> 4) {
            case 1: W->rx_log = logs[more % 9]; break;
            case 2: W->tx_log = logs[more % 9]; break;
            case 3: W->rx_offset = offsets[more % 8]; break;
            case 4: W->tx_offset = offsets[more % 8]; break;
            case 5: W->short_by = 1 + more; break;
            case 6: W->null_output = 1 + more % 3; break;
            case 7: W->short_interface = true; break;
            default: W->rx_offset = offsets[more % 8]; W->tx_log = logs[(more >> 3) % 9]; break;
        }
    }
    trace("  ConnectQueues rx 2^%u+%u tx 2^%u+%u short %u null %d", W->rx_log, W->rx_offset,
          W->tx_log, W->tx_offset, W->short_by, W->null_output);
    IOBufferMemoryDescriptor *ifmd = nullptr;
    IOMemoryDescriptor *rxqmd = nullptr, *txqmd = nullptr;
    const auto result = W->port->ConnectQueues(&ifmd, &rxqmd, &txqmd, nullptr, nullptr, 0, 0, 0, 0);
    OSSafeReleaseNULL(ifmd);
    OSSafeReleaseNULL(rxqmd);
    OSSafeReleaseNULL(txqmd);
    trace("    -> 0x%x", unsigned(result));
    if (result == kIOReturnSuccess) {
        if (W->queue == nullptr) fail("ConnectQueues succeeded without usable queues");
        W->connected = true;
    } else if (result != kIOReturnBusy) {
        drop_queues();  // the kernel gives up on these queues
    }
}

void run_operation(FuzzedDataProvider &input) {
    const uint8_t operation = input.ConsumeIntegral<uint8_t>() % 13;
    const bool strict = W->strict;
    const auto queue = W->queue;
    if (operation <= 7 && !port_usable()) return;
    switch (operation) {
        case 0:
            if (strict && W->connected) return;
            connect(input);
            break;
        case 1:
            if (strict && !W->connected) return;
            trace("  DisconnectQueues");
            W->port->DisconnectQueues();
            drop_queues();
            break;
        case 2: {
            if (strict && (!W->connected || W->active)) return;
            const auto result = W->port->HwActivate();
            trace("  HwActivate -> 0x%x", unsigned(result));
            if (result == kIOReturnSuccess) {
                if (!W->connected) fail("HwActivate succeeded without queues");
                W->active = true;
                W->rx_faults = 0;
            }
            break;
        }
        case 3:
            if (strict && !W->active) return;
            trace("  HwDeactivate");
            W->port->HwDeactivate();
            W->active = W->kicked = false;
            break;
        case 4: {
            const uint8_t lines = input.ConsumeIntegral<uint8_t>();
            trace("  HwProgramMCR");
            W->port->HwProgramMCR(lines & 1, lines & 2);
            break;
        }
        case 5: {  // the client writes
            uint32_t count = input.ConsumeIntegral<uint8_t>() * 33u;
            if (queue == nullptr || W->corrupt || !W->connected || (strict && !W->active)) return;
            const uint32_t space = W->tx_size - 1 - (queue->txPI - queue->txCI);
            if (count > space) count = space;
            for (uint32_t index = 0; index < count; ++index) {
                const uint8_t byte = uint8_t(W->written.size() * 13 + 1);
                W->tx[(queue->txPI + index) & (W->tx_size - 1)] = byte;
                W->written.push_back(byte);
            }
            queue->txPI += count;
            trace("  write %u, TxDataAvailable", count);
            W->port->TxDataAvailable();
            if (W->active) W->kicked = true;
            break;
        }
        case 6:
            trace("  TxDataAvailable");
            W->port->TxDataAvailable();
            break;
        case 7: {  // the client reads
            uint32_t count = input.ConsumeIntegral<uint8_t>() * 33u;
            if (queue == nullptr || W->corrupt) return;
            const uint32_t available = queue->rxPI - queue->rxCI;
            if (count > available) count = available;
            queue->rxCI += count;
            trace("  read %u, RxFreeSpaceAvailable", count);
            W->port->RxFreeSpaceAvailable();
            break;
        }
        case 8: {  // a receive transfer completes
            const uint8_t how = input.ConsumeIntegral<uint8_t>();
            const uint8_t seed = input.ConsumeIntegral<uint8_t>();
            auto pipe = W->in_pipe;
            if (pipe == nullptr || !pipe->pending) return;
            static const IOReturn errors[] = {kIOUSBPipeStalled, kIOReturnNotResponding,
                                              kIOReturnTimeout, kIOReturnError};
            IOReturn status = (how & 3) == 3 ? errors[(how >> 2) & 3] : kIOReturnSuccess;
            uint32_t count = how >> 4;
            if ((how & 3) == 1) count = pipe->pending_length - (how >> 4);
            if ((how & 3) == 2) count = strict ? 64u * (how >> 4) : 0x1000u * (how >> 4) + 1;
            if (pipe->aborted && (strict || (how & 4))) { status = kIOReturnAborted; count = 0; }
            complete_receive(status, count, seed);
            break;
        }
        case 9: {  // a transmit transfer completes
            const uint8_t how = input.ConsumeIntegral<uint8_t>();
            auto pipe = W->out_pipe;
            if (pipe == nullptr || !pipe->pending) return;
            IOReturn status = (how & 3) == 3 ? kIOUSBPipeStalled : kIOReturnSuccess;
            if (pipe->aborted && (strict || (how & 4))) status = kIOReturnAborted;
            trace("  transmit complete status 0x%x", unsigned(status));
            complete(pipe, status, status == kIOReturnSuccess ? pipe->pending_length : 0);
            break;
        }
        case 10:
            if (!port_usable()) return;
            stop_port();
            break;
        case 11:
            // The kernel stops clients before their provider.
            if (W->iface_stopped || (strict && port_usable())) return;
            stop_interface();
            break;
        case 12: {
            const uint32_t value = input.ConsumeIntegral<uint32_t>();
            const uint8_t which = input.ConsumeIntegral<uint8_t>();
            if (strict || queue == nullptr || !port_usable()) return;
            trace("  corrupt ring index %u", which & 3);
            (&queue->rxPI)[which & 3] = value;
            W->corrupt = true;
            W->kicked = false;
            break;
        }
    }
    // A synchronous abort has finished the transfers. Their completions are
    // normally handed over before the kernel's next call; with "late" set
    // they may arrive after it (I could not find this ordering documented).
    if (strict && !W->late) flush_aborted();
    check_invariants();
}

void build_descriptor(FuzzedDataProvider &input) {
    auto &bytes = W->descriptor;
    bytes = {9, 2, 0, 0, 1, 1, 0, 0x80, 250};
    const uint8_t shape = input.ConsumeIntegral<uint8_t>();
    bytes.insert(bytes.end(), {9, 4, uint8_t(shape >> 4), 0, 3, 0xff, 0, 0, 0});
    if ((shape & 8) == 0) {  // the EC25 layout: interrupt IN, bulk IN, bulk OUT
        bytes.insert(bytes.end(), {7, 5, 0x83, 3, 10, 0, 9, 7, 5, 0x82, 2, 0, 2, 0,
                                   7, 5, 0x02, 2, 0, 2, 0});
    } else {
        for (int count = shape & 7; count > 0; --count) {
            const uint8_t kind = input.ConsumeIntegral<uint8_t>();
            const uint8_t value = input.ConsumeIntegral<uint8_t>();
            if (kind < 200) bytes.insert(bytes.end(), {7, 5, value, uint8_t(kind & 3), 0, 2, 0});
            else if (kind < 230) bytes.insert(bytes.end(), {9, 4, value, 0, 0, 0xff, 0xff, 0xff, 0});
            else bytes.insert(bytes.end(), {5, 0x24, value, 0, 0});
        }
    }
    bytes[2] = uint8_t(bytes.size());
    bytes[3] = uint8_t(bytes.size() >> 8);
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    FuzzedDataProvider input(data, size);
    World world;
    W = &world;
    const uint8_t mode = input.ConsumeIntegral<uint8_t>();
    world.strict = (mode & 1) == 0;
    world.create_mode = (mode >> 1) & 3;
    world.late = (mode & 8) != 0;
    if (world.create_mode == 3 || (world.strict && world.create_mode == 2)) world.create_mode = 0;
    for (auto &index : world.fail_at) index = input.ConsumeIntegral<uint8_t>();
    build_descriptor(input);
    trace("--- %s, create mode %d", world.strict ? "strict" : "loose", world.create_mode);

    world.usb = new IOUSBHostInterface;
    world.iface = new QuectelSerialInterface;
    if (!world.iface->init()) abort();
    const auto result = world.iface->Start(world.usb);
    trace("  interface Start -> 0x%x", unsigned(result));
    world.port_started = world.port != nullptr && world.port->IsStarted();
    if (result == kIOReturnSuccess) {
        if (!port_usable() || !world.in_pipe || !world.out_pipe)
            fail("interface Start succeeded without a started port and two pipes");
        for (int count = 0; count < 96 && input.remaining_bytes() > 0; ++count)
            run_operation(input);
    }

    // Unplug: the port goes first, then the interface. A failed Start is not
    // followed by Stop.
    trace("  teardown");
    if (port_usable()) stop_port();
    flush_aborted();
    if (result == kIOReturnSuccess && !world.iface_stopped) stop_interface();
    flush_aborted();
    for (auto pipe : {world.in_pipe, world.out_pipe}) {
        if (pipe == nullptr) continue;
        if (pipe->pending) { pipe->buffer->release(); pipe->action->release(); }
        pipe->release();
    }
    drop_queues();
    OSSafeReleaseNULL(world.port);
    world.iface->release();
    world.usb->release();
    if (world.open_count != 0) fail("USB interface left open");
    if (live_objects != 0) {
        fprintf(stderr, "%d objects\n", live_objects);
        fail("objects leaked (retain without release)");
    }
    W = nullptr;
    return 0;
}
