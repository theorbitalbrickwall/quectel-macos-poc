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
AddressSanitizer of clang 19 hangs at start on macOS 27. `run.sh` looks for
`clang++` in `PATH`, then Homebrew's `llvm`, then MacPorts `clang++-mp-22`,
and takes the first one that has libFuzzer. Only the MacPorts one has been
tried. To choose the compiler yourself:

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

- The fake DriverKit is how Claude Fable 5.2 (the LLM that wrote it) understands
  Apple's frameworks, written from the public headers. A clean run says the driver logic is consistent with that
  model. It says nothing about real macOS or a real modem. Finding 3 below
  is an example of what the model missed.
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

## Findings so far

`regressions/` holds the inputs. All are fixed; `run.sh` replays them first.

1. A failed transmit submit dropped one 4096 byte chunk and then stopped.
   The rest of the client's data stayed in the ring until the next write.
2. If a transmit completion from the previous open arrived after the port was
   reopened and written to, the new data was never sent.

3. The transmit buffer was created with `kIOMemoryDirectionOut` only.
   DriverKit maps such a buffer read-only in the driver, so the first write
   to a port crashed. This one was found on real hardware, not by the fuzzer:
   the fake DriverKit did not model it. It does now, and the input is kept so
   the mistake cannot come back.

The fuzzer itself found no memory safety problem.
