# Fuzzing the driver

The driver only runs inside DriverKit on a Mac, so it cannot be fuzzed
directly. Here the real driver sources (`../Driver/*.cpp`) are compiled as a
normal program against a small fake DriverKit (`shim/`) and driven by
[libFuzzer](https://llvm.org/docs/LibFuzzer.html) with AddressSanitizer and
UBSan.

The fuzzer input decides everything the driver cannot control:

- the USB descriptors, and which framework calls fail;
- what the kernel does: open, close, activate, write, read, in which order;
- what the modem does: data, transfer errors, replies longer than requested;
- when the port and the interface are stopped (unplug).

The harness checks more than crashes: bytes must not be lost, repeated or
changed in either direction, transfers must keep going while the port is
open, and every object must be released at the end.

## Run

On Linux (this is what CI runs):

```bash
sudo apt-get install clang libclang-rt-18-dev
```

On macOS you need an LLVM clang, version 22, from any source (MacPorts,
Homebrew, llvm.org). Xcode's clang does not include libFuzzer, and the
AddressSanitizer of clang 19 hangs at start on macOS 27. `run.sh` takes the
first of `clang++` in `PATH`, Homebrew's `llvm` and MacPorts `clang++-mp-22`
that has libFuzzer. To choose the compiler yourself:

```bash
CXX=/path/to/clang++ serial-driver/fuzz/run.sh 60
```

On macOS `run.sh` also turns leak detection on (it is off by default there).
`lsan-macos.supp` hides one leak that is inside libFuzzer itself.

Then, on either system:

```bash
serial-driver/fuzz/run.sh 300
```

The number is the run time in seconds. A finding stops the run and saves the
input as `build/crash-...`. To see which calls it made:

```bash
serial-driver/fuzz/run.sh --replay serial-driver/fuzz/build/crash-FILE
```

## Limits

- The fake DriverKit was written from Apple's public headers. A clean run
  says the driver logic is consistent with that model, nothing about real
  macOS or a real modem. Regression 3 below is an example of what it missed.
- `shim/QuectelSerial*.h` replace the headers that Apple's `iig` tool
  generates. When a method is added to a `.iig` file, add it there too.
- One thread only. Real DriverKit runs both classes on one dispatch queue, so
  this matches, but queue setup itself is not tested.

## Modes

Bit 0 of the first input byte selects the mode:

- strict: the kernel only makes sensible calls. All checks are on.
- loose: hostile kernel (bad queue sizes, corrupt ring indices, calls in any
  order). Only memory errors and leaks are reported.

Bit 3 additionally lets the completion of an aborted transfer arrive after
the next kernel call instead of before it.

## Regressions

`regressions/` holds one input per fixed bug; `run.sh` replays them first.

1. A failed transmit submit dropped one chunk and stalled the rest.
2. A transmit completion from the previous open, arriving after a reopen,
   stalled the new data.
3. The transmit buffer was mapped read-only, so the first write crashed.
   Found on hardware, not by the fuzzer; the fake DriverKit now models it.
