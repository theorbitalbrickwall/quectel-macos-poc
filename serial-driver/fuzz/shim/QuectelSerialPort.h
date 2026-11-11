// SPDX-License-Identifier: CC0-1.0
// Stand-in for the header that Apple's iig tool generates from
// Driver/QuectelSerialPort.iig. Keep the method list in sync with it.
#pragma once
#include "driverkit_shim.h"

struct QuectelSerialPort_IVars;
#define QuectelSerialPort_Start_Args IOService *provider
#define QuectelSerialPort_Stop_Args IOService *provider
#define QuectelSerialPort_ConnectQueues_Args IOBufferMemoryDescriptor **ifmd, \
    IOMemoryDescriptor **rxqmd, IOMemoryDescriptor **txqmd, \
    IOMemoryDescriptor *in_rxqmd, IOMemoryDescriptor *in_txqmd, \
    uint32_t in_rxqoffset, uint32_t in_txqoffset, uint8_t in_rxqlogsz, uint8_t in_txqlogsz
#define QuectelSerialPort_DisconnectQueues_Args void
#define QuectelSerialPort_HwActivate_Args void
#define QuectelSerialPort_HwDeactivate_Args void
#define QuectelSerialPort_HwResetFIFO_Args bool tx, bool rx
#define QuectelSerialPort_HwSendBreak_Args bool sendBreak
#define QuectelSerialPort_HwProgramUART_Args uint32_t baudRate, uint8_t nDataBits, \
    uint8_t nHalfStopBits, uint8_t parity
#define QuectelSerialPort_HwProgramBaudRate_Args uint32_t baudRate
#define QuectelSerialPort_HwProgramMCR_Args bool dtr, bool rts
#define QuectelSerialPort_HwGetModemStatus_Args bool *cts, bool *dsr, bool *ri, bool *dcd
#define QuectelSerialPort_HwProgramLatencyTimer_Args uint32_t latency
#define QuectelSerialPort_HwProgramFlowControl_Args uint32_t arg, uint8_t xon, uint8_t xoff
#define QuectelSerialPort_TxDataAvailable_Args void
#define QuectelSerialPort_RxFreeSpaceAvailable_Args void

class QuectelSerialPort : public IOUserSerial {
    using super = IOUserSerial;
public:
    bool init() override;
    void free() override;
    kern_return_t Start(IOService *provider, void * = nullptr) override { return Start_Impl(provider); }
    kern_return_t Stop(IOService *provider, void * = nullptr) override { return Stop_Impl(provider); }
    kern_return_t ConnectQueues(IOBufferMemoryDescriptor **ifmd, IOMemoryDescriptor **rxqmd,
        IOMemoryDescriptor **txqmd, IOMemoryDescriptor *in_rxqmd, IOMemoryDescriptor *in_txqmd,
        uint32_t in_rxqoffset, uint32_t in_txqoffset, uint8_t in_rxqlogsz, uint8_t in_txqlogsz,
        void * = nullptr) override {
        return ConnectQueues_Impl(ifmd, rxqmd, txqmd, in_rxqmd, in_txqmd, in_rxqoffset,
            in_txqoffset, in_rxqlogsz, in_txqlogsz);
    }
    kern_return_t DisconnectQueues(void * = nullptr) override { return DisconnectQueues_Impl(); }
    kern_return_t HwActivate() override { return HwActivate_Impl(); }
    kern_return_t HwDeactivate() override { return HwDeactivate_Impl(); }
    kern_return_t HwProgramMCR(bool dtr, bool rts) override { return HwProgramMCR_Impl(dtr, rts); }
    void TxDataAvailable() override { TxDataAvailable_Impl(); }
    void RxFreeSpaceAvailable() override { RxFreeSpaceAvailable_Impl(); }

    kern_return_t Start_Impl(QuectelSerialPort_Start_Args);
    kern_return_t Stop_Impl(QuectelSerialPort_Stop_Args);
    kern_return_t ConnectQueues_Impl(QuectelSerialPort_ConnectQueues_Args);
    kern_return_t DisconnectQueues_Impl(QuectelSerialPort_DisconnectQueues_Args);
    kern_return_t HwActivate_Impl(QuectelSerialPort_HwActivate_Args);
    kern_return_t HwDeactivate_Impl(QuectelSerialPort_HwDeactivate_Args);
    kern_return_t HwResetFIFO_Impl(QuectelSerialPort_HwResetFIFO_Args);
    kern_return_t HwSendBreak_Impl(QuectelSerialPort_HwSendBreak_Args);
    kern_return_t HwProgramUART_Impl(QuectelSerialPort_HwProgramUART_Args);
    kern_return_t HwProgramBaudRate_Impl(QuectelSerialPort_HwProgramBaudRate_Args);
    kern_return_t HwProgramMCR_Impl(QuectelSerialPort_HwProgramMCR_Args);
    kern_return_t HwGetModemStatus_Impl(QuectelSerialPort_HwGetModemStatus_Args);
    kern_return_t HwProgramLatencyTimer_Impl(QuectelSerialPort_HwProgramLatencyTimer_Args);
    kern_return_t HwProgramFlowControl_Impl(QuectelSerialPort_HwProgramFlowControl_Args);
    void TxDataAvailable_Impl(QuectelSerialPort_TxDataAvailable_Args);
    void RxFreeSpaceAvailable_Impl(QuectelSerialPort_RxFreeSpaceAvailable_Args);

    bool IsStarted();
    uint32_t CopyTransmit(uint8_t *out, uint32_t capacity);
    void ConsumeTransmit(uint32_t size);
    void Receive(const uint8_t *data, uint32_t size);
    void Cleanup();

    QuectelSerialPort_IVars *ivars = nullptr;
};
