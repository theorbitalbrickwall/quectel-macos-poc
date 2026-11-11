// SPDX-License-Identifier: CC0-1.0
// A small fake of the parts of DriverKit, USBDriverKit and SerialDriverKit
// that the driver uses, so the real driver sources compile and run on Linux
// under a fuzzer. Behaviour is implemented in ../fuzz_driver.cpp.
//
// This is a model written from the public headers, not Apple's code. Where
// the real behaviour is not known the fuzzer is allowed to choose.
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <sys/mman.h>
#include <vector>

typedef int kern_return_t;
typedef kern_return_t IOReturn;
enum : int {
    kIOReturnSuccess = 0,
    kIOReturnError = int(0xe00002bc),
    kIOReturnNoMemory = int(0xe00002bd),
    kIOReturnBadArgument = int(0xe00002c2),
    kIOReturnUnsupported = int(0xe00002c7),
    kIOReturnBusy = int(0xe00002d5),
    kIOReturnTimeout = int(0xe00002d6),
    kIOReturnNotReady = int(0xe00002d8),
    kIOReturnAborted = int(0xe00002eb),
    kIOReturnNotResponding = int(0xe00002ed),
    kIOUSBPipeStalled = int(0xe000404f),
};
enum : uint64_t { kIOMemoryDirectionIn = 1, kIOMemoryDirectionOut = 2, kIOMemoryDirectionInOut = 3 };
enum : uint32_t { kIOUSBAbortAsynchronous = 0, kIOUSBAbortSynchronous = 1 };
#define kIOServiceDefaultQueueName "Default"

#define SUPERDISPATCH nullptr
#define IMPL(cls, name) cls::name##_Impl(cls##_##name##_Args)
#define OSDynamicCast(type, object) dynamic_cast<type *>(object)
#define OSSafeReleaseNULL(object) do { if (object) { (object)->release(); (object) = nullptr; } } while (0)
#define IONewZero(type, count) static_cast<type *>(calloc((count), sizeof(type)))
#define IOSafeDeleteNULL(pointer, type, count) do { ::free(pointer); (pointer) = nullptr; } while (0)
#define OS_LOG_DEFAULT 0
void os_log(int log, const char *format, ...) __attribute__((format(printf, 2, 3)));

struct IOAddressSegment { uint64_t address; uint64_t length; };

struct IOUSBDescriptorHeader { uint8_t bLength, bDescriptorType; } __attribute__((packed));
struct IOUSBConfigurationDescriptor {
    uint8_t bLength, bDescriptorType; uint16_t wTotalLength;
    uint8_t bNumInterfaces, bConfigurationValue, iConfiguration, bmAttributes, MaxPower;
} __attribute__((packed));
struct IOUSBInterfaceDescriptor {
    uint8_t bLength, bDescriptorType, bInterfaceNumber, bAlternateSetting, bNumEndpoints,
        bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, iInterface;
} __attribute__((packed));
struct IOUSBEndpointDescriptor {
    uint8_t bLength, bDescriptorType, bEndpointAddress, bmAttributes;
    uint16_t wMaxPacketSize; uint8_t bInterval;
} __attribute__((packed));

class OSObject {
public:
    OSObject();
    virtual ~OSObject();
    virtual bool init() { return true; }
    virtual void free() { delete this; }
    void retain();
    void release();
    int refs = 1;
};

class OSString : public OSObject {
public:
    static OSString *withCString(const char *) { return new OSString; }
};

class OSDictionary : public OSObject {
public:
    static OSDictionary *withCapacity(uint32_t) { return new OSDictionary; }
    bool setObject(const char *, OSObject *value) { value->retain(); values.push_back(value); return true; }
    ~OSDictionary() override { for (auto value : values) value->release(); }
    std::vector<OSObject *> values;
};

class IODispatchQueue : public OSObject {};
class IOService;

class OSAction : public OSObject {
public:
    int kind = 0;
};

class IOMemoryMap;
class IOMemoryDescriptor : public OSObject {
public:
    ~IOMemoryDescriptor() override {
        if (mapped != 0) munmap(data, mapped); else ::free(data);
    }
    kern_return_t CreateMapping(uint64_t options, uint64_t address, uint64_t offset,
        uint64_t length, uint64_t alignment, IOMemoryMap **map);
    uint8_t *data = nullptr;
    uint64_t length = 0;
    size_t mapped = 0;  // not 0: data is a read-only mmap of this size
};

class IOBufferMemoryDescriptor : public IOMemoryDescriptor {
public:
    kern_return_t SetLength(uint64_t length);
    kern_return_t GetAddressRange(IOAddressSegment *range);
};

class IOMemoryMap : public OSObject {
public:
    ~IOMemoryMap() override { memory->release(); }
    uint64_t GetAddress() { return reinterpret_cast<uint64_t>(memory->data); }
    uint64_t GetLength() { return memory->length; }
    IOMemoryDescriptor *memory = nullptr;
};

class IOService : public OSObject {
public:
    virtual kern_return_t Start(IOService *provider, void *supermethod = nullptr);
    virtual kern_return_t Stop(IOService *provider, void *supermethod = nullptr);
    kern_return_t RegisterService();
    kern_return_t Create(IOService *provider, const char *propertiesKey, IOService **result);
    kern_return_t Terminate(uint64_t options);
    kern_return_t CopyDispatchQueue(const char *name, IODispatchQueue **queue);
    kern_return_t SetDispatchQueue(const char *name, IODispatchQueue *queue);
    kern_return_t SetProperties(OSDictionary *properties);
};

class IOUSBHostPipe : public OSObject {
public:
    kern_return_t AsyncIO(IOMemoryDescriptor *buffer, uint32_t length, OSAction *completion,
        uint32_t timeout);
    kern_return_t Abort(uint32_t options, kern_return_t reason, IOService *forClient);
    kern_return_t ClearStall(bool withRequest);
    uint8_t address = 0;
    bool pending = false, aborted = false;
    IOMemoryDescriptor *buffer = nullptr;
    OSAction *action = nullptr;
    uint32_t pending_length = 0;
};

class IOUSBHostInterface : public IOService {
public:
    kern_return_t Open(IOService *forClient, uint32_t options, void *arg);
    kern_return_t Close(IOService *forClient, uint32_t options);
    const IOUSBConfigurationDescriptor *CopyConfigurationDescriptor();
    const IOUSBInterfaceDescriptor *GetInterfaceDescriptor(
        const IOUSBConfigurationDescriptor *configuration);
    kern_return_t CopyPipe(uint8_t address, IOUSBHostPipe **pipe);
    kern_return_t CreateIOBuffer(uint64_t options, uint64_t capacity,
        IOBufferMemoryDescriptor **buffer);
    kern_return_t DeviceRequest(uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue,
        uint16_t wIndex, uint16_t wLength, IOMemoryDescriptor *data,
        uint16_t *bytesTransferred, uint32_t timeout);
};

void IOUSBHostFreeDescriptor(const void *descriptor);
const IOUSBEndpointDescriptor *IOUSBGetNextEndpointDescriptor(
    const IOUSBConfigurationDescriptor *configuration,
    const IOUSBInterfaceDescriptor *interface, const IOUSBDescriptorHeader *current);

namespace driverkit { namespace serial {
struct SerialPortInterface {
    uint32_t rxPI, rxCI, txPI, txCI;
    uint32_t rxqoffset, txqoffset;
    uint32_t rxqlogsz, txqlogsz;
};
}}

class IOUserSerial : public IOService {
public:
    virtual kern_return_t ConnectQueues(IOBufferMemoryDescriptor **ifmd,
        IOMemoryDescriptor **rxqmd, IOMemoryDescriptor **txqmd,
        IOMemoryDescriptor *in_rxqmd, IOMemoryDescriptor *in_txqmd,
        uint32_t in_rxqoffset, uint32_t in_txqoffset,
        uint8_t in_rxqlogsz, uint8_t in_txqlogsz, void *supermethod = nullptr);
    virtual kern_return_t DisconnectQueues(void *supermethod = nullptr);
    virtual kern_return_t HwActivate() = 0;
    virtual kern_return_t HwDeactivate() = 0;
    virtual kern_return_t HwProgramMCR(bool dtr, bool rts) = 0;
    virtual void TxDataAvailable() = 0;
    virtual void RxFreeSpaceAvailable() = 0;
    void RxDataAvailable();
    void TxFreeSpaceAvailable();
    kern_return_t RxError(bool overrun, bool gotBreak, bool framingError, bool parityError);
};
