// SPDX-License-Identifier: CC0-1.0
#include "QuectelSerialInterface.h"
#include "QuectelSerialPort.h"

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/USBDriverKitDefs.h>
#include <USBDriverKit/AppleUSBDescriptorParsing.h>
#include <USBDriverKit/IOUSBHostFamilyDefinitions.h>

// Bulk IN requests must be a multiple of the endpoint's max packet size
// (512 at high speed, 64 at full speed); 4096 satisfies both.
static const uint32_t kBufferSize = 4096;
static const uint32_t kMaxConsecutiveRxErrors = 5;

struct QuectelSerialInterface_IVars {
    IOUSBHostInterface *interface;
    IOUSBHostPipe *in_pipe;
    IOUSBHostPipe *out_pipe;
    IOBufferMemoryDescriptor *rx_buffer;
    IOBufferMemoryDescriptor *tx_buffer;
    IOAddressSegment rx_address;
    IOAddressSegment tx_address;
    OSAction *rx_action;
    OSAction *tx_action;
    QuectelSerialPort *port;
    uint32_t interface_number;
    uint32_t tx_size;
    // Bumped on every open, so a completion belonging to a previous client
    // can never advance the ring of a new one.
    uint32_t generation;
    uint32_t tx_generation;
    uint32_t rx_errors;
    bool interface_open;
    bool stopping;
    bool active;
    bool rx_pending;
    bool tx_busy;
};

bool QuectelSerialInterface::init() {
    if (!super::init()) return false;
    ivars = IONewZero(QuectelSerialInterface_IVars, 1);
    return ivars != nullptr;
}

void QuectelSerialInterface::free() {
    Cleanup();
    IOSafeDeleteNULL(ivars, QuectelSerialInterface_IVars, 1);
    super::free();
}

uint32_t QuectelSerialInterface::InterfaceNumber() { return ivars->interface_number; }
bool QuectelSerialInterface::IsStopping() { return ivars->stopping; }

kern_return_t IMPL(QuectelSerialInterface, Start) {
    auto result = super::Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;
    ivars->interface = OSDynamicCast(IOUSBHostInterface, provider);
    if (ivars->interface == nullptr) return kIOReturnBadArgument;
    ivars->interface->retain();
    result = ivars->interface->Open(this, 0, nullptr);
    if (result != kIOReturnSuccess) { Cleanup(); return result; }
    ivars->interface_open = true;

    // Find the bulk pair. The interrupt endpoint (serial state notifications)
    // is not needed for an AT command channel and is left alone.
    const auto configuration = ivars->interface->CopyConfigurationDescriptor();
    const auto descriptor = configuration
        ? ivars->interface->GetInterfaceDescriptor(configuration) : nullptr;
    if (descriptor == nullptr) {
        if (configuration) IOUSBHostFreeDescriptor(configuration);
        Cleanup(); return kIOReturnUnsupported;
    }
    ivars->interface_number = descriptor->bInterfaceNumber;
    uint8_t in_address = 0, out_address = 0;
    const IOUSBDescriptorHeader *previous = nullptr;
    for (;;) {
        const auto endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, previous);
        if (endpoint == nullptr) break;
        previous = reinterpret_cast<const IOUSBDescriptorHeader *>(endpoint);
        if ((endpoint->bmAttributes & 3) != 2) continue;
        if ((endpoint->bEndpointAddress & 0x80) != 0) {
            if (in_address == 0) in_address = endpoint->bEndpointAddress;
        } else if (out_address == 0) {
            out_address = endpoint->bEndpointAddress;
        }
    }
    IOUSBHostFreeDescriptor(configuration);
    if (in_address == 0 || out_address == 0) {
        os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u has no bulk pair, ignoring",
               ivars->interface_number);
        Cleanup(); return kIOReturnUnsupported;
    }
    result = ivars->interface->CopyPipe(in_address, &ivars->in_pipe);
    if (result == kIOReturnSuccess)
        result = ivars->interface->CopyPipe(out_address, &ivars->out_pipe);

    if (result == kIOReturnSuccess)
        result = ivars->interface->CreateIOBuffer(kIOMemoryDirectionIn, kBufferSize, &ivars->rx_buffer);
    if (result == kIOReturnSuccess) result = ivars->rx_buffer->SetLength(kBufferSize);
    if (result == kIOReturnSuccess) result = ivars->rx_buffer->GetAddressRange(&ivars->rx_address);
    // Not kIOMemoryDirectionOut: DriverKit maps an out-only buffer read-only in
    // the driver's address space, and filling it crashes (seen on macOS 27).
    if (result == kIOReturnSuccess)
        result = ivars->interface->CreateIOBuffer(kIOMemoryDirectionInOut, kBufferSize, &ivars->tx_buffer);
    if (result == kIOReturnSuccess) result = ivars->tx_buffer->SetLength(kBufferSize);
    if (result == kIOReturnSuccess) result = ivars->tx_buffer->GetAddressRange(&ivars->tx_address);
    if (result == kIOReturnSuccess) result = CreateActionReceiveComplete(0, &ivars->rx_action);
    if (result == kIOReturnSuccess) result = CreateActionTransmitComplete(0, &ivars->tx_action);
    if (result != kIOReturnSuccess) { Cleanup(); return result; }

    IOService *service = nullptr;
    result = Create(this, "PortProperties", &service);
    auto port = OSDynamicCast(QuectelSerialPort, service);
    if (result != kIOReturnSuccess || port == nullptr) {
        os_log(OS_LOG_DEFAULT, "QuectelSerial: creating port for interface %u failed 0x%x",
               ivars->interface_number, result);
        OSSafeReleaseNULL(service); Cleanup(); return kIOReturnUnsupported;
    }
    ivars->port = port;
    if (!port->IsStarted()) result = port->Start(this);
    if (result != kIOReturnSuccess) { Cleanup(); return result; }

    result = RegisterService();
    os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u ready (in 0x%x, out 0x%x), 0x%x",
           ivars->interface_number, in_address, out_address, result);
    if (result != kIOReturnSuccess) Cleanup();
    return result;
}

kern_return_t IMPL(QuectelSerialInterface, Stop) {
    Cleanup();
    return super::Stop(provider, SUPERDISPATCH);
}

void QuectelSerialInterface::Cleanup() {
    if (ivars == nullptr) return;
    ivars->stopping = true;
    ivars->active = false;
    if (ivars->in_pipe != nullptr)
        (void)ivars->in_pipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->out_pipe != nullptr)
        (void)ivars->out_pipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    if (ivars->port != nullptr) {
        (void)ivars->port->Terminate(0);
        OSSafeReleaseNULL(ivars->port);
    }
    OSSafeReleaseNULL(ivars->rx_action);
    OSSafeReleaseNULL(ivars->tx_action);
    OSSafeReleaseNULL(ivars->rx_buffer);
    OSSafeReleaseNULL(ivars->tx_buffer);
    OSSafeReleaseNULL(ivars->in_pipe);
    OSSafeReleaseNULL(ivars->out_pipe);
    if (ivars->interface_open) {
        (void)ivars->interface->Close(this, 0);
        ivars->interface_open = false;
    }
    OSSafeReleaseNULL(ivars->interface);
}

kern_return_t QuectelSerialInterface::SubmitReceive() {
    if (ivars->rx_pending || !ivars->active || ivars->stopping) return kIOReturnSuccess;
    const auto result = ivars->in_pipe->AsyncIO(ivars->rx_buffer, kBufferSize, ivars->rx_action, 0);
    if (result == kIOReturnSuccess) ivars->rx_pending = true;
    else os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u receive submit failed 0x%x",
                ivars->interface_number, result);
    return result;
}

kern_return_t QuectelSerialInterface::SetPortActive(bool active) {
    if (ivars->stopping) return active ? kIOReturnNotReady : kIOReturnSuccess;
    if (active) {
        ++ivars->generation;
        ivars->rx_errors = 0;
        ivars->active = true;
        return SubmitReceive();
    }
    ivars->active = false;
    (void)ivars->in_pipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    (void)ivars->out_pipe->Abort(kIOUSBAbortSynchronous, kIOReturnAborted, nullptr);
    return kIOReturnSuccess;
}

// Same request the Linux "option" driver sends: CDC SET_CONTROL_LINE_STATE
// addressed to this interface. Quectel firmware uses DTR to decide whether a
// host is listening, so URCs may be withheld until it is raised.
kern_return_t QuectelSerialInterface::SetLineState(bool dtr, bool rts) {
    if (ivars->stopping || ivars->interface == nullptr) return kIOReturnNotReady;
    uint16_t transferred = 0;
    const uint16_t value = uint16_t((dtr ? 1u : 0u) | (rts ? 2u : 0u));
    const auto result = ivars->interface->DeviceRequest(0x21, 0x22, value,
        uint16_t(ivars->interface_number), 0, nullptr, &transferred, 1000);
    if (result != kIOReturnSuccess)
        os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u line state request failed 0x%x",
               ivars->interface_number, result);
    return result;
}

void IMPL(QuectelSerialInterface, ReceiveComplete) {
    (void)action; (void)completionTimestamp;
    ivars->rx_pending = false;
    if (ivars->stopping || !ivars->active || ivars->port == nullptr) return;
    if (status == kIOReturnSuccess) {
        ivars->rx_errors = 0;
        if (actualByteCount > kBufferSize) actualByteCount = kBufferSize;
        if (actualByteCount != 0)
            ivars->port->Receive(reinterpret_cast<const uint8_t *>(ivars->rx_address.address),
                                 actualByteCount);
    } else if (status != kIOReturnAborted) {
        os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u receive failed 0x%x",
               ivars->interface_number, status);
        // Stop retrying when the device is gone or keeps failing; the port is
        // reopened (or the modem replugged) to recover.
        if (++ivars->rx_errors > kMaxConsecutiveRxErrors) return;
        (void)ivars->in_pipe->ClearStall(true);
    }
    (void)SubmitReceive();
}

void QuectelSerialInterface::PumpTransmit() {
    if (ivars->stopping || !ivars->active || ivars->tx_busy || ivars->port == nullptr) return;
    for (;;) {
        const uint32_t size = ivars->port->CopyTransmit(
            reinterpret_cast<uint8_t *>(ivars->tx_address.address), kBufferSize);
        if (size == 0) return;
        ivars->tx_size = size;
        ivars->tx_generation = ivars->generation;
        ivars->tx_busy = true;
        const auto result = ivars->out_pipe->AsyncIO(ivars->tx_buffer, size, ivars->tx_action, 5000);
        if (result == kIOReturnSuccess) return;
        os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u transmit submit failed 0x%x",
               ivars->interface_number, result);
        ivars->tx_busy = false;
        // Drop the chunk instead of leaving the client blocked forever, then
        // try the next one: no completion will come to continue from.
        ivars->port->ConsumeTransmit(size);
    }
}

void IMPL(QuectelSerialInterface, TransmitComplete) {
    (void)action; (void)completionTimestamp; (void)actualByteCount;
    ivars->tx_busy = false;
    if (ivars->stopping || ivars->port == nullptr) return;
    if (status != kIOReturnSuccess && status != kIOReturnAborted) {
        os_log(OS_LOG_DEFAULT, "QuectelSerial: interface %u transmit failed 0x%x",
               ivars->interface_number, status);
        (void)ivars->out_pipe->ClearStall(true);
    }
    if (!ivars->active) return;
    // On failure the chunk is dropped as well; AT traffic is request/response
    // and the client will time out and retry. A completion left over from a
    // previous open consumes nothing, but the new client may have written
    // while tx_busy was still set, so transmission restarts either way.
    if (ivars->tx_generation == ivars->generation) ivars->port->ConsumeTransmit(ivars->tx_size);
    PumpTransmit();
}
