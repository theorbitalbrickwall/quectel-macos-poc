// SPDX-License-Identifier: CC0-1.0 AND MIT
// Contains code from idy/ch348-macos, Copyright (c) 2026 idy, under the MIT
// licence: see serial-driver/LICENSE-ch348-macos.
#include "QuectelSerialPort.h"
#include "QuectelSerialInterface.h"

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSString.h>
#include <SerialDriverKit/SerialDriverKit.h>
#include <SerialDriverKit/SerialPortInterface.h>
#include <stdio.h>

// Ring convention (same as the ch348-macos driver, which is verified on
// hardware): rxPI/rxCI/txPI/txCI are free-running 32-bit counters, only the
// byte offset into the power-of-two ring is masked, and one slot stays empty.

struct QuectelSerialPort_IVars {
    QuectelSerialInterface *owner;
    bool started;
    bool active;
    IOBufferMemoryDescriptor *interface_memory;
    IOMemoryDescriptor *rx_memory;
    IOMemoryDescriptor *tx_memory;
    IOMemoryMap *interface_map;
    IOMemoryMap *rx_map;
    IOMemoryMap *tx_map;
    driverkit::serial::SerialPortInterface *queue;
    uint8_t *rx;
    uint8_t *tx;
    uint32_t rx_size;
    uint32_t tx_size;
};

bool QuectelSerialPort::init() {
    if (!super::init()) return false;
    ivars = IONewZero(QuectelSerialPort_IVars, 1);
    return ivars != nullptr;
}

void QuectelSerialPort::free() {
    Cleanup();
    IOSafeDeleteNULL(ivars, QuectelSerialPort_IVars, 1);
    super::free();
}

bool QuectelSerialPort::IsStarted() { return ivars->started; }

kern_return_t IMPL(QuectelSerialPort, Start) {
    kern_return_t result = super::Start(provider, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;
    ivars->owner = OSDynamicCast(QuectelSerialInterface, provider);
    if (ivars->owner == nullptr) return kIOReturnBadArgument;

    // Run on the owner's queue so port and USB callbacks never race.
    IODispatchQueue *queue = nullptr;
    result = ivars->owner->CopyDispatchQueue(kIOServiceDefaultQueueName, &queue);
    if (result != kIOReturnSuccess) return result;
    result = SetDispatchQueue(kIOServiceDefaultQueueName, queue);
    queue->release();
    if (result != kIOReturnSuccess) return result;

    // /dev/cu.quectel<interface number>, e.g. /dev/cu.quectel2 for the AT port.
    char suffix[16];
    snprintf(suffix, sizeof(suffix), "%u", ivars->owner->InterfaceNumber());
    auto names = OSDictionary::withCapacity(2);
    auto name = OSString::withCString("quectel");
    auto ending = OSString::withCString(suffix);
    if (names == nullptr || name == nullptr || ending == nullptr) {
        OSSafeReleaseNULL(names); OSSafeReleaseNULL(name); OSSafeReleaseNULL(ending);
        return kIOReturnNoMemory;
    }
    names->setObject("IOTTYBaseName", name);
    names->setObject("IOTTYSuffix", ending);
    result = SetProperties(names);
    names->release(); name->release(); ending->release();
    if (result != kIOReturnSuccess) return result;

    ivars->started = true;
    return RegisterService();
}

kern_return_t IMPL(QuectelSerialPort, Stop) {
    (void)HwDeactivate_Impl();
    ivars->started = false;
    Cleanup();
    ivars->owner = nullptr;
    return super::Stop(provider, SUPERDISPATCH);
}

// Called by IOUserSerial when a client opens the port.
kern_return_t IMPL(QuectelSerialPort, ConnectQueues) {
    if (ivars->active) return kIOReturnBusy;
    Cleanup();
    auto result = super::ConnectQueues(ifmd, rxqmd, txqmd, in_rxqmd, in_txqmd,
        in_rxqoffset, in_txqoffset, in_rxqlogsz, in_txqlogsz, SUPERDISPATCH);
    if (result != kIOReturnSuccess) return result;
    if (!*ifmd || !*rxqmd || !*txqmd) return kIOReturnNoMemory;
    ivars->interface_memory = *ifmd;
    ivars->rx_memory = *rxqmd;
    ivars->tx_memory = *txqmd;
    ivars->interface_memory->retain();
    ivars->rx_memory->retain();
    ivars->tx_memory->retain();
    result = ivars->interface_memory->CreateMapping(0, 0, 0, 0, 0, &ivars->interface_map);
    if (result == kIOReturnSuccess)
        result = ivars->rx_memory->CreateMapping(0, 0, 0, 0, 0, &ivars->rx_map);
    if (result == kIOReturnSuccess)
        result = ivars->tx_memory->CreateMapping(0, 0, 0, 0, 0, &ivars->tx_map);
    if (result != kIOReturnSuccess) { Cleanup(); return result; }
    if (ivars->interface_map->GetLength() < sizeof(*ivars->queue)) {
        Cleanup(); return kIOReturnBadArgument;
    }
    ivars->queue = reinterpret_cast<driverkit::serial::SerialPortInterface *>(
        ivars->interface_map->GetAddress());
    const auto rx_logsz = __atomic_load_n(&ivars->queue->rxqlogsz, __ATOMIC_RELAXED);
    const auto tx_logsz = __atomic_load_n(&ivars->queue->txqlogsz, __ATOMIC_RELAXED);
    const auto rx_offset = __atomic_load_n(&ivars->queue->rxqoffset, __ATOMIC_RELAXED);
    const auto tx_offset = __atomic_load_n(&ivars->queue->txqoffset, __ATOMIC_RELAXED);
    if (rx_logsz == 0 || tx_logsz == 0 || rx_logsz > 30 || tx_logsz > 30) {
        Cleanup(); return kIOReturnBadArgument;
    }
    ivars->rx_size = 1u << rx_logsz;
    ivars->tx_size = 1u << tx_logsz;
    if (uint64_t(rx_offset) + ivars->rx_size > ivars->rx_map->GetLength() ||
        uint64_t(tx_offset) + ivars->tx_size > ivars->tx_map->GetLength()) {
        Cleanup(); return kIOReturnBadArgument;
    }
    ivars->rx = reinterpret_cast<uint8_t *>(ivars->rx_map->GetAddress()) + rx_offset;
    ivars->tx = reinterpret_cast<uint8_t *>(ivars->tx_map->GetAddress()) + tx_offset;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, DisconnectQueues) {
    (void)HwDeactivate_Impl();
    Cleanup();
    return super::DisconnectQueues(SUPERDISPATCH);
}

void QuectelSerialPort::Cleanup() {
    if (ivars == nullptr) return;
    ivars->queue = nullptr;
    ivars->rx = nullptr;
    ivars->tx = nullptr;
    OSSafeReleaseNULL(ivars->tx_map);
    OSSafeReleaseNULL(ivars->rx_map);
    OSSafeReleaseNULL(ivars->interface_map);
    OSSafeReleaseNULL(ivars->tx_memory);
    OSSafeReleaseNULL(ivars->rx_memory);
    OSSafeReleaseNULL(ivars->interface_memory);
}

kern_return_t IMPL(QuectelSerialPort, HwActivate) {
    if (ivars->owner == nullptr || ivars->owner->IsStopping() || ivars->queue == nullptr)
        return kIOReturnNotReady;
    const auto result = ivars->owner->SetPortActive(true);
    if (result == kIOReturnSuccess) ivars->active = true;
    return result;
}

kern_return_t IMPL(QuectelSerialPort, HwDeactivate) {
    ivars->active = false;
    if (ivars->owner == nullptr || ivars->owner->IsStopping()) return kIOReturnSuccess;
    (void)ivars->owner->SetLineState(false, false);
    return ivars->owner->SetPortActive(false);
}

// The port is a USB pipe, not a UART: there is no baud rate, framing, FIFO or
// flow control to program. Accept whatever the client asks for.
kern_return_t IMPL(QuectelSerialPort, HwProgramUART) {
    (void)baudRate; (void)nDataBits; (void)nHalfStopBits; (void)parity;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwProgramBaudRate) {
    (void)baudRate;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwResetFIFO) {
    (void)tx; (void)rx;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwSendBreak) {
    (void)sendBreak;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwProgramMCR) {
    if (ivars->owner == nullptr) return kIOReturnNotReady;
    // A modem that rejects the request is still usable; do not fail the open.
    (void)ivars->owner->SetLineState(dtr, rts);
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwGetModemStatus) {
    if (!cts || !dsr || !ri || !dcd) return kIOReturnBadArgument;
    *cts = true; *dsr = true; *ri = false; *dcd = true;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwProgramLatencyTimer) {
    (void)latency;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QuectelSerialPort, HwProgramFlowControl) {
    (void)arg; (void)xon; (void)xoff;
    return kIOReturnSuccess;
}

void IMPL(QuectelSerialPort, TxDataAvailable) {
    if (ivars->owner != nullptr && ivars->active) ivars->owner->PumpTransmit();
}

void IMPL(QuectelSerialPort, RxFreeSpaceAvailable) {}

uint32_t QuectelSerialPort::CopyTransmit(uint8_t *out, uint32_t capacity) {
    if (!ivars->active || ivars->queue == nullptr) return 0;
    const uint32_t producer = __atomic_load_n(&ivars->queue->txPI, __ATOMIC_ACQUIRE);
    const uint32_t consumer = __atomic_load_n(&ivars->queue->txCI, __ATOMIC_RELAXED);
    uint32_t count = producer - consumer;
    if (count >= ivars->tx_size) return 0; // corrupt indices; send nothing
    if (count > capacity) count = capacity;
    for (uint32_t index = 0; index < count; ++index)
        out[index] = ivars->tx[(consumer + index) & (ivars->tx_size - 1u)];
    return count;
}

void QuectelSerialPort::ConsumeTransmit(uint32_t size) {
    if (ivars->queue == nullptr) return;
    const uint32_t consumer = __atomic_load_n(&ivars->queue->txCI, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->queue->txCI, consumer + size, __ATOMIC_RELEASE);
    TxFreeSpaceAvailable();
}

void QuectelSerialPort::Receive(const uint8_t *data, uint32_t size) {
    if (!ivars->active || ivars->queue == nullptr) return;
    const uint32_t producer = __atomic_load_n(&ivars->queue->rxPI, __ATOMIC_RELAXED);
    const uint32_t consumer = __atomic_load_n(&ivars->queue->rxCI, __ATOMIC_ACQUIRE);
    const uint32_t used = producer - consumer;
    if (used >= ivars->rx_size) return;
    const uint32_t space = ivars->rx_size - 1u - used;
    const uint32_t count = size < space ? size : space;
    for (uint32_t index = 0; index < count; ++index)
        ivars->rx[(producer + index) & (ivars->rx_size - 1u)] = data[index];
    // A reader that falls behind loses the tail and is told about it.
    if (count < size) (void)RxError(true, false, false, false);
    if (count == 0) return;
    __atomic_store_n(&ivars->queue->rxPI, producer + count, __ATOMIC_RELEASE);
    RxDataAvailable();
}
