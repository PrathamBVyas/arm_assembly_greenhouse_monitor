# Smart Greenhouse Monitor
### EGC-121 Computer Architecture — IIIT Bangalore · April 2025

**Authors:** Pratham Vyas (BC2025078) · Yashamit Dawane (BC2025119)  
**Platform:** BBC micro:bit v2 (ARM Cortex-M4 / nRF52833)  
**Language:** ARM Thumb-2 Assembly (bare-metal, zero OS overhead)

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Concepts Demonstrated](#2-architecture-concepts-demonstrated)
3. [Repository Structure](#3-repository-structure)
4. [Hardware Requirements](#4-hardware-requirements)
5. [Build & Flash Instructions](#5-build--flash-instructions)
6. [Configuration](#6-configuration)
7. [Step-by-Step Evaluator Demo Guide](#7-step-by-step-evaluator-demo-guide)
8. [LED Display Reference](#8-led-display-reference)
9. [Button Reference](#9-button-reference)
10. [FSM State Diagram](#10-fsm-state-diagram)
11. [Data Structure: Triple Segment Tree](#11-data-structure-triple-segment-tree)
12. [Error Handling](#12-error-handling)
13. [Known Constraints](#13-known-constraints)

---

## 1. Project Overview

This project implements a **bare-metal temperature data logger and statistical query engine** on the micro:bit v2. It has a real-world framing as a **Smart Greenhouse Monitor**: the device continuously samples the on-chip temperature sensor, stores readings into a custom **Triple Segment Tree** in RAM, and lets the user interactively query any sub-range of the recorded data for its **Maximum**, **Minimum**, or **Average** temperature — all without an operating system, runtime library, or any high-level language.

Every subsystem — GPIO configuration, LED multiplexing, button debouncing, memory management, and the segment tree itself — is written entirely in ARM Thumb-2 assembly and interacts with hardware exclusively through memory-mapped I/O registers.

---

## 2. Architecture Concepts Demonstrated

| Concept | Where It Appears |
|---|---|
| **Memory-Mapped I/O** | Direct GPIO register reads/writes for buttons (`0x50000000`) and TEMP peripheral (`0x4000C000`) |
| **Finite State Machine** | 6-state FSM governing the entire runtime with deterministic transitions |
| **Stack Operations** | `PUSH`/`POP` with `{r4-r9, lr}` callee-save conventions throughout all subroutines |
| **Instruction Pipelining** | Column data pre-loaded before row activation to eliminate GPIO race-condition ghosting |
| **Custom Data Structures** | Triple Segment Tree (Min/Max/Sum) in raw RAM — O(log N) range queries, O(log N) updates |
| **Bit Manipulation** | LSL/LSR for parent/child traversal, barrel-shifter addressing for font lookup, `mvn`+`and` for active-low column inversion |
| **IT Block Compliance** | Thumb-2 conditional execution with explicit `IT`/`ITE` blocks for all predicated instructions |
| **Hardware Debouncing** | Software busy-wait debouncer + release-guard loop suppressing all contact bounce |
| **POV Multiplexing** | Time-division row-scan at sufficient refresh rate for human persistence of vision |
| **Sliding Window Marquee** | 11-bit virtual frame buffer scrolled across the 5-column display for two-digit results |

---

## 3. Repository Structure

```
.
├── main.s          # Complete system — FSM, segment trees, display engine, all subroutines
├── LED.s           # LED library (provided by course) — GPIO direction init, pin write helpers
├── Makefile        # Build rules: compile → link → produce .hex
└── README.md       # This file
```

> All application logic lives in `main.s`. `LED.s` is a course-provided hardware abstraction layer; `main.s` calls `init_leds`, `write_row_pins`, and `write_column_pins` from it.

---

## 4. Hardware Requirements

- BBC **micro:bit v2** (nRF52833 SoC — Cortex-M4, 64 MHz)
- USB-A to micro-USB cable
- A computer with `arm-none-eabi-gcc` and `make` installed

> **micro:bit v1 is not supported.** The project uses nRF52833-specific register addresses (e.g., the TEMP peripheral at `0x4000C000`) that differ from the nRF51822 on v1.

---

## 5. Build & Flash Instructions

### 5.1 Download the COMP2300 Toolchain

Clone the course template repository and the toolchain:

```bash
git clone https://github.com/code-help-tutor/COMP2300-6300-ENGN2219-Computer-Organisation-and-Program-Execution

git clone https://github.com/cpmpercussion/comp2300-toolchain ~/.comp2300
```

Extract and set up the toolchain:

```bash
cd ~/.comp2300
make toolchain-linux.zip
unzip toolchain-linux.zip -d ~/.comp2300/linux
```

Add it to your PATH:

```bash
echo 'export PATH="$HOME/.comp2300/linux/arm-none-eabi/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

Verify: `arm-none-eabi-as --version`

### 5.2 Place the Source File

Inside the cloned template repo, navigate to the Assignment 2 folder:

```
COMP2300-.../comp2300-2022-assignment-2-main/src/main.s
```

**Replace the contents of `main.s` with the `main.s` from this repository.** You can copy-paste or overwrite the file directly.

### 5.3 Bind the micro:bit via USBIPD (Windows with WSL)

Connect the micro:bit via USB, then in a Windows terminal (PowerShell/cmd):

```powershell
usbipd list                        # find the micro:bit bus ID
usbipd bind --busid <BUSID>
usbipd attach --wsl --busid <BUSID>
```

Verify inside WSL with `lsusb` — you should see `NXP ARM mbed (ID 0d28:0204)`.

### 5.4 Build and Flash

Open **two terminal tabs** in the assignment directory:

```bash
cd ~/microbit/COMP2300-6300-ENGN2219-Computer-Organisation-and-Program-Execution/comp2300-2022-assignment-2-main
```

**Tab A — Start OpenOCD:**

```bash
openocd -f interface/cmsis-dap.cfg -f target/nrf52.cfg
```

You should see `Listening on port 3333` — leave this running.

**Tab B — Build and flash via GDB:**

```bash
arm-none-eabi-gdb program.elf
```

Once the GDB prompt appears, run these commands in sequence:

```gdb
make clean
make
target extended-remote localhost:3333
monitor reset halt
load
continue
```

The code is now flashed onto the micro:bit and running. The LED matrix will show a **center dot** within one second, indicating the system is live and waiting in the IDLE state.

---

## 6. Configuration

Two constants at the top of `main.s` control the two most important runtime parameters. Change only these lines — nothing else needs to be touched:

```asm
@ Line 9-10 in main.s
.equ MAX_READINGS,   100       @ Maximum number of temperature samples (1–128)
.equ TEMP_INTERVAL,  20000000  @ Busy-wait count between samples
                               @ Empirically: ~4,000,000 counts ≈ 1 second at 64 MHz
                               @ Default 20,000,000 ≈ 5 seconds
```

**To speed up recording for a quick demo**, change `TEMP_INTERVAL` to `4000000` (≈ 1 second per reading) before building.

---

## 7. Step-by-Step Evaluator Demo Guide

This section walks through a complete demonstration cycle. Follow these steps in order to observe every feature of the system.

---

### Step 0 — Confirm the board is live

After flashing, the **center LED** (row 2, col 2) stays on. This is the IDLE state. No readings have been taken. The board is waiting.

**What to observe:**  single dot on the matrix.

---

### Step 1 — Start recording (`Button A` once)

Press **Button A** (left button, marked `A` on the board face) once.

**What happens:**
- All previous state is cleared to zero.
- The board immediately takes its **first temperature reading** from the on-chip sensor.
- The matrix **flashes all 25 LEDs briefly** (full-bright blink) to confirm each sample was recorded.
- The board then waits `TEMP_INTERVAL` counts before the next sample.
- This repeats automatically every ~5 seconds (or 1 second if you reduced the interval).

**What to observe:** A brief full-matrix flash each time a reading is recorded. The board acquires readings silently between flashes.

> **Tip for evaluators:** Wait for at least 3–5 readings (3–5 flashes) before stopping, so the range queries are more meaningful. For a quicker demo, set `TEMP_INTERVAL` to `4000000` to get a reading every second.

---

### Step 2 — Stop recording (`Button A` once)

Press **Button A** once while recording is active.

**What happens:**
- Recording stops immediately (even mid-interval).
- The total count of readings taken so far is locked in.
- The system transitions to **Query Type Selection**.

> **Error case:** If you stop recording before even one reading is taken (i.e., you press A to start and immediately press A again), the matrix will **flash all LEDs 4 times** (the error signal) and return to IDLE. At least one reading must exist to proceed.

---

### Step 3 — Select query type

The display now shows a single digit: **`0`**, **`1`**, or **`2`**.

| Digit shown | Query |
|---|---|
| `0` | **Maximum** temperature in the selected range |
| `1` | **Minimum** temperature in the selected range |
| `2` | **Average** temperature in the selected range (integer) |

**Controls:**
- **Button B** (right button) — cycle forward through `0 → 1 → 2 → 0 → ...`
- **Button A** — confirm current selection

**Demo suggestion:** Select `0` (MAX) for the first run-through. Confirm with A.

---

### Step 4 — Select left bound L

The display shows the current value of **L** (the left/start index of the query range, zero-indexed).

L starts at `0` and is bounded to `[0, total_readings − 1]`.

**Controls:**
- **Button B** — increment L by 1 (wraps back to `0` after the last valid index)
- **Button A** — confirm L and move to selecting R

**Demo suggestion:** Leave L at `0` and confirm immediately with A to query from the first reading.

---

### Step 5 — Select right bound R

The display shows the current value of **R** (the right/end index of the query range, zero-indexed, inclusive).

R starts at the same value as L and is bounded to `[L, total_readings − 1]`. It **cannot go below L**, so an inverted range is impossible.

**Controls:**
- **Button B** — increment R by 1 (wraps back to L, not to 0, when it exceeds the last valid index)
- **Button A** — confirm R and execute the query

**Demo suggestion:** Press B several times to set R to the last reading (e.g., if 5 readings were taken, R will cap at `4`), then confirm with A to query the full range.

---

### Step 6 — View the result

The query executes instantly (O(log N) segment tree traversal) and the result is displayed on the LED matrix.

**Single-digit results (0–9):** The digit is shown statically.

**Two-digit results (10–99):** A **scrolling marquee** animation plays — the tens digit enters from the right, scrolls left, exits, and the ones digit follows. The scroll repeats continuously until you dismiss it.

**What to observe:** The temperature value (integer Celsius). Verify it is plausible for the room temperature. For MAX it should be the highest value recorded; for MIN the lowest; for AVG the integer mean.

---

### Step 7 — Run more queries on the same data

After viewing the result, **do not press A yet.** The board loops the display continuously.

To run another query (different type or different range) **on the same recorded data**, press **Button A** once. The board returns to IDLE, then press A again to go back to recording — **but you will lose the current data** (init_data is called on every IDLE → RECORD transition).

> If you want to query the same dataset multiple times without re-recording, see below.

**To query same data again without re-recording:**

Actually, pressing A in SHOW_RESULT resets everything (by design — it is the full reset trigger). So for the demo, plan your queries: record data, run MAX, show evaluator, then record again with a note of the temperature to verify MIN and AVG manually.

---

### Step 8 — Full reset (`Button A` in result state)

Press **Button A** once while the result is displayed.

**What happens:** All three segment trees are wiped, counters reset to zero, and the system returns to IDLE ( center dot).

The board is now ready for another complete cycle. This completes one full demo loop.

---

### Suggested Full Demo Sequence for Evaluators

| # | Action | Expected Display |
|---|---|---|
| 1 | Power on / after flash |  center dot |
| 2 | Press A | Full-matrix blink per reading (every ~5 sec) |
| 3 | Wait for 5+ readings | 5 confirm-blinks observed |
| 4 | Press A to stop | Digit `0` appears (MAX selected) |
| 5 | Press B twice | Digit changes: `0` → `1` → `2` |
| 6 | Press B once | Back to `1` (MIN) |
| 7 | Press A | L selection: shows `0` |
| 8 | Press A | R selection: shows `0` |
| 9 | Press B until R = 4 | Shows `1`, `2`, `3`, `4` in sequence |
| 10 | Press A | MIN over readings [0..4] scrolls/displays |
| 11 | Note the value | Should be lowest temp recorded |
| 12 | Press A | Returns to IDLE — full reset confirmed |

---

## 8. LED Display Reference

### Single-digit display (values 0–9)
The digit is rendered as a 5×5 block glyph using row-multiplexing (POV). Each of the 5 rows is activated sequentially; at sufficient refresh rate, all rows appear simultaneously lit.

### Two-digit scrolling marquee (values 10–99)
The tens and ones digits are packed into an 11-bit virtual frame buffer (5 bits tens + 1 bit gap + 5 bits ones) held in a CPU register. A `scroll_offset` variable (0..16) is incremented each refresh cycle; the current 5-column window is extracted with `LSR + AND 0b11111`. The result is a smooth left-scrolling ticker display.

### Error signal
Four rapid full-matrix flashes (all 25 LEDs on/off × 4). Triggered when a query is attempted with zero readings recorded, or when the range bounds are internally inconsistent.

### IDLE signal
Single center LED (row 2, column 2) static led. Indicates the system is ready and waiting for Button A.

### Recording confirm signal
Brief full-matrix flash after each successful temperature reading is inserted into the segment trees.

---

## 9. Button Reference

| Button | Label | Action |
|---|---|---|
| Left button | **A** | Confirm / Advance state / Reset (in result state) |
| Right button | **B** | Cycle / Increment current selection |

Button A is active-LOW (GPIO pin 14, `PIN_CNF[14]` configured with internal pull-up). Button B is active-LOW (GPIO pin 23). Both are debounced in software with a ~20 ms busy-wait dead zone plus a release-guard loop that prevents a held button from firing multiple transitions.

---

## 10. FSM State Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │                                             │
                    ▼                                             │ Press A
              ┌───────────┐    Press A                           │ (Reset)
              │  0: IDLE  │──────────────────────────────────────┤
              │ ( dot)    │                                       │
              │           │                                       │
              └───────────┘                                       │
                    │                                             │
                    │ Press A                                     │
                    ▼                                             │
           ┌──────────────────┐                                  │
           │  1: RECORDING    │◄──── reading blink every ~5s     │
           │  (full blink     │                                   │
           │   per sample)    │─── Auto-stop at MAX_READINGS      │
           └──────────────────┘                                   │
                    │                                             │
                    │ Press A  (or capacity reached)              │
                    ▼                                             │
           ┌──────────────────┐   Press B                        │
           │ 2: SEL QUERY     │──────────┐                       │
           │ 0=MAX 1=MIN 2=AVG│◄─────────┘ (cycle 0→1→2→0)       │
           └──────────────────┘                                   │
                    │                                             │
                    │ Press A                                     │
                    ▼                                             │
           ┌──────────────────┐   Press B                        │
           │   3: SEL L       │──────────┐                       │
           │  (left bound)    │◄─────────┘ (increment, wrap→0)   │
           └──────────────────┘                                   │
                    │                                             │
                    │ Press A                                     │
                    ▼                                             │
           ┌──────────────────┐   Press B                        │
           │   4: SEL R       │──────────┐                       │
           │  (right bound)   │◄─────────┘ (increment, wrap→L)   │
           └──────────────────┘                                   │
                    │                                             │
                    │ Press A (query executes)                    │
                    ▼                                             │
           ┌──────────────────┐                                   │
           │ 5: SHOW RESULT   │───────────────────────────────────┘
           │  (scroll/static) │  Press A
           └──────────────────┘
```

---

## 11. Data Structure: Triple Segment Tree

Three independent segment trees are maintained in parallel in `.data` RAM:

| Tree | Size | Leaf sentinel | Internal node identity |
|---|---|---|---|
| `max_tree` | 256 nodes × 4 bytes = 1 KB | `0x80000000` (INT_MIN) | 0 |
| `min_tree` | 256 nodes × 4 bytes = 1 KB | `0x7FFFFFFF` (INT_MAX) | 0 |
| `sum_tree` | 256 nodes × 4 bytes = 1 KB | `0x00000000` | 0 |

**Total RAM for trees: 3 KB.**

Indexing follows the standard 1-based binary heap layout: node `n` has left child `2n` and right child `2n+1`. Parent traversal is a single `LSR #1`. Leaf nodes occupy indices `[TREE_LEAVES, 2×TREE_LEAVES − 1]` = `[128, 255]`. Node 0 is unused.

**Insertion (O(log 128) = O(7)):** Temperature written to leaf, then a bubble-up loop propagates max/min/sum upward to the root. All three trees are updated in one sequential pass.

**Range query (O(log 128) = O(7)):** Standard iterative segment tree traversal: if the left pointer is a right child (odd), include it and advance; if the right pointer is a left child (even), include it and retreat; shift both pointers to their parents. Repeat until they cross.

**Average:** `sum_tree` range query result divided by `(R − L + 1)` using the hardware `UDIV` instruction.

---

## 12. Error Handling

| Condition | Detection | Response |
|---|---|---|
| Recording stopped with 0 readings | `total_readings == 0` check after stop | 4× full-matrix flash, return to IDLE |
| R < L after confirm | Explicit `cmp r5, r4` + `blt error_bad_range` | 4× full-matrix flash, return to IDLE |
| L out of range | UI clamps: `L < total_readings`, wraps to 0 | Never reaches invalid state |
| R below L | UI clamps: R wraps to L (not to 0) | R ≥ L is a strict invariant |
| Division by zero (AVG) | Impossible — range is always ≥ 1 reading by invariant | N/A |
| MAX_READINGS exceeded | `cmp r1, #MAX_READINGS; bge stop_recording` | Stops cleanly, moves to query selection |
| Button held across state transitions | Release-guard loop in IDLE state | Swallows residual press from prior reset |

---

## 13. Known Constraints

- **Display range is [0, 99].** Results outside this range are clamped before display. Real indoor temperatures are always within this range; extreme readings would indicate a hardware fault.
- **Integer arithmetic only.** Average is truncated (floor division). A reading of 23.75 °C displays as 23.
- **MAX_READINGS must not exceed 128** without also changing `TREE_LEAVES` and `TREE_SIZE`. The segment tree is statically allocated at compile time.
- **No persistent storage.** All recorded data is lost on power cycle or reset. The device is a single-session logger by design.
- **Busy-wait timing only.** `TEMP_INTERVAL` is calibrated for 64 MHz. If the clock is configured differently (e.g., after a low-power mode change), the interval will drift proportionally.

---

*EGC-121 Computer Architecture · IIIT Bangalore · April 2025*  
*Pratham Vyas (BC2025078) · Yashamit Dawane (BC2025119)*
