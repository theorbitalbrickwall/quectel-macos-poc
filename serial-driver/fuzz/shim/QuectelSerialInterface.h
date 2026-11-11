// SPDX-License-Identifier: CC0-1.0
// Stand-in for the header that Apple's iig tool generates from
// Driver/QuectelSerialInterface.iig. Keep the method list in sync with it.
#pragma once
#include "driverkit_shim.h"

struct QuectelSerialInterface_IVars;
#define QuectelSerialInterface_Start_Args IOService *provider
#define QuectelSerialInterface_Stop_Args IOService *provider
#define QuectelSerialInterface_ReceiveComplete_Args OSAction *action, IOReturn status, \
    uint32_t actualByteCount, uint64_t completionTimestamp
#define QuectelSerialInterface_TransmitComplete_Args QuectelSerialInterface_ReceiveComplete_Args

class QuectelSerialInterface : public IOService {
    using super = IOService;
public:
    bool init() override;
    void free() override;
    kern_return_t Start(IOService *provider, void * = nullptr) override { return Start_Impl(provider); }
    kern_return_t Stop(IOService *provider, void * = nullptr) override { return Stop_Impl(provider); }
    kern_return_t Start_Impl(QuectelSerialInterface_Start_Args);
    kern_return_t Stop_Impl(QuectelSerialInterface_Stop_Args);
    void ReceiveComplete_Impl(QuectelSerialInterface_ReceiveComplete_Args);
    void TransmitComplete_Impl(QuectelSerialInterface_TransmitComplete_Args);
    kern_return_t CreateActionReceiveComplete(size_t referenceSize, OSAction **action);
    kern_return_t CreateActionTransmitComplete(size_t referenceSize, OSAction **action);

    kern_return_t SetPortActive(bool active);
    kern_return_t SetLineState(bool dtr, bool rts);
    void PumpTransmit();
    uint32_t InterfaceNumber();
    bool IsStopping();
    kern_return_t SubmitReceive();
    void Cleanup();

    QuectelSerialInterface_IVars *ivars = nullptr;
};
