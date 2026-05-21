
.syntax unified
.global main

@ ============================================================
@ EASY-CHANGE CONFIGURATION
@ Modify only these two lines to tune timing and capacity.
@ ============================================================
.equ MAX_READINGS,   100       @ Max temperature samples (must be <= TREE_LEAVES)
.equ TEMP_INTERVAL,  20000000  @ Busy-wait count ≈ 5 sec at 16 MHz.
                                @ Tune empirically: ~4M counts ≈ 1 sec.

@ ============================================================
@ INTERNAL CONSTANTS  (do NOT change unless MAX_READINGS > 128)
@ ============================================================
.equ TREE_LEAVES,    128       @ Next power-of-2 >= MAX_READINGS
.equ TREE_SIZE,      256       @ 2 * TREE_LEAVES (node 0 unused)

@ FSM states
.equ STATE_IDLE,        0
.equ STATE_RECORDING,   1
.equ STATE_SEL_QUERY,   2
.equ STATE_SEL_L,       3
.equ STATE_SEL_R,       4
.equ STATE_SHOW_RESULT, 5

@ Query type codes  (shown as digit on LED during selection)
.equ QUERY_MAX, 0              @ displayed as "0"
.equ QUERY_MIN, 1              @ displayed as "1"
.equ QUERY_AVG, 2              @ displayed as "2"

@ ============================================================
@ DATA SECTION
@ ============================================================
.data
.align 2
button_event:   .space 4       @ NEW: Latches asynchronous button presses
@ Three segment trees: 256 nodes × 4 bytes = 1024 bytes each
max_tree: .space 1024
min_tree: .space 1024
sum_tree: .space 1024

@ Application state
current_state:  .space 4
total_readings: .space 4
query_type:     .space 4
query_l:        .space 4
query_r:        .space 4
query_result:   .space 4

@ ============================================================
@ TEXT SECTION
@ ============================================================
.text
.type main, %function
main:
    bl init_hardware
    bl init_leds               @ from LED.s: sets up GPIO direction, blanks display
    bl init_data
    b  fsm_loop

@ ============================================================
@ FSM MAIN LOOP
@ ============================================================
fsm_loop:
    ldr r0, =current_state
    ldr r1, [r0]
    cmp r1, #STATE_IDLE
    beq handle_idle
    cmp r1, #STATE_RECORDING
    beq handle_recording
    cmp r1, #STATE_SEL_QUERY
    beq handle_sel_query
    cmp r1, #STATE_SEL_L
    beq handle_sel_l
    cmp r1, #STATE_SEL_R
    beq handle_sel_r
    cmp r1, #STATE_SHOW_RESULT
    beq handle_show_result
    b   fsm_loop

@ ============================================================
@ STATE 0: IDLE
@ Pulses center LED.  Button A once → start recording.
@ ============================================================
handle_idle:
    @ Guard: wait for A to be physically released before listening
    @ (prevents held button from previous reset from firing)
idle_release_guard:
    bl poll_button_a
    cmp r0, #1
    beq idle_release_guard

    @ Pulse center LED, then check
    bl show_idle_pulse
    bl poll_button_a
    cmp r0, #1
    bne handle_idle

    @ Button A pressed → fresh init and begin recording
    bl init_data               @ clears trees and resets all counters
    ldr r0, =current_state
    mov r1, #STATE_RECORDING
    str r1, [r0]
    bl debounce_delay
    b   fsm_loop

@ ============================================================
@ STATE 1: RECORDING
@ Takes a reading immediately, then waits TEMP_INTERVAL.
@ Stops when MAX_READINGS reached OR Button A pressed once.
@ ============================================================
handle_recording:
    @ --- Capacity check ---
    ldr r0, =total_readings
    ldr r1, [r0]
    cmp r1, #MAX_READINGS
    bge stop_recording

    @ --- Sample temperature ---
    bl  read_temperature       @ r0 = Celsius (integer)

    @ --- Insert into all three trees ---
    ldr r1, =total_readings
    ldr r2, [r1]               @ r2 = leaf index (0-based)
    bl  insert_reading         @ (r0=temp, r2=index)

    @ --- Advance counter ---
    ldr r1, =total_readings
    ldr r2, [r1]
    add r2, r2, #1
    str r2, [r1]

    @ --- Brief blink: user can see a reading was taken ---
    bl blink_confirm

    @ --- Wait TEMP_INTERVAL; returns early (r0=1) if A pressed ---
    bl interval_wait_or_button
    cmp r0, #1
    beq stop_recording

    b handle_recording

stop_recording:
    @ --- Error: no data at all ---
    ldr r0, =total_readings
    ldr r1, [r0]
    cmp r1, #0
    beq error_no_data

    @ --- Seed query defaults ---
    ldr r0, =query_type
    mov r1, #QUERY_MAX
    str r1, [r0]
    ldr r0, =query_l
    mov r1, #0
    str r1, [r0]
    ldr r0, =query_r
    mov r1, #0
    str r1, [r0]

    ldr r0, =current_state
    mov r1, #STATE_SEL_QUERY
    str r1, [r0]
    bl  debounce_delay
    b   fsm_loop

@ ============================================================
@ STATE 2: SELECT QUERY TYPE
@ LED shows:  0 = MAX,  1 = MIN,  2 = AVG
@ Button B → cycle forward.  Button A → confirm.
@ ============================================================
handle_sel_query:
    ldr r0, =query_type
    ldr r1, [r0]
    mov r0, r1
    bl  show_digit             @ display 0, 1, or 2

    bl  poll_buttons           @ r0: 1=A, 2=B, 0=none
    cmp r0, #1
    beq sel_query_confirm
    cmp r0, #2
    beq sel_query_cycle
    b   handle_sel_query

sel_query_cycle:
    ldr r0, =query_type
    ldr r1, [r0]
    add r1, r1, #1
    cmp r1, #3                 @ wrap MAX→MIN→AVG→MAX
    blt sel_query_no_wrap
    mov r1, #0
sel_query_no_wrap:
    str r1, [r0]
    bl  debounce_delay
    b   handle_sel_query

sel_query_confirm:
    ldr r0, =current_state
    mov r1, #STATE_SEL_L
    str r1, [r0]
    bl  debounce_delay
    b   fsm_loop

@ ============================================================
@ STATE 3: SELECT L  (left bound, 0-indexed)
@ LED shows current L value.
@ Button B → increment (wraps to 0 after total_readings-1).
@ Button A → confirm.
@ ============================================================
handle_sel_l:
    ldr r0, =query_l
    ldr r1, [r0]
    mov r0, r1
    bl  show_number

    bl  poll_buttons
    cmp r0, #1
    beq sel_l_confirm
    cmp r0, #2
    beq sel_l_inc
    b   handle_sel_l

sel_l_inc:
    ldr r0, =query_l
    ldr r1, [r0]
    add r1, r1, #1
    ldr r2, =total_readings
    ldr r3, [r2]
    cmp r1, r3                 @ L must be < total_readings
    blt sel_l_store
    mov r1, #0                 @ wrap to 0
sel_l_store:
    str r1, [r0]
    bl  debounce_delay
    b   handle_sel_l

sel_l_confirm:
    @ Seed R = L (so R always starts >= L)
    ldr r0, =query_l
    ldr r1, [r0]
    ldr r0, =query_r
    str r1, [r0]
    ldr r0, =current_state
    mov r1, #STATE_SEL_R
    str r1, [r0]
    bl  debounce_delay
    b   fsm_loop

@ ============================================================
@ STATE 4: SELECT R  (right bound, 0-indexed)
@ R is constrained to [L .. total_readings-1].
@ Button B → increment (wraps back to L, not to 0).
@ Button A → confirm and compute result.
@ ============================================================
handle_sel_r:
    ldr r0, =query_r
    ldr r1, [r0]
    mov r0, r1
    bl  show_number

    bl  poll_buttons
    cmp r0, #1
    beq sel_r_confirm
    cmp r0, #2
    beq sel_r_inc
    b   handle_sel_r

sel_r_inc:
    ldr r0, =query_r
    ldr r1, [r0]
    add r1, r1, #1
    ldr r2, =total_readings
    ldr r3, [r2]
    cmp r1, r3                 @ R must be < total_readings
    blt sel_r_store
    ldr r2, =query_l           @ wrap back to L (not 0)
    ldr r1, [r2]
sel_r_store:
    str r1, [r0]
    bl  debounce_delay
    b   handle_sel_r

sel_r_confirm:
    @ --- Load user_l and user_r into r4, r5 (preserved across bl calls) ---
    ldr r0, =query_l
    ldr r4, [r0]               @ r4 = user_l
    ldr r0, =query_r
    ldr r5, [r0]               @ r5 = user_r

    @ --- Sanity: R >= L  (UI enforces it, but guard anyway) ---
    cmp r5, r4
    blt error_bad_range

    @ --- Convert to inclusive tree node indices ---
    add r1, r4, #TREE_LEAVES   @ tree_l
    add r2, r5, #TREE_LEAVES   @ tree_r

    @ --- Dispatch on query type ---
    ldr r0, =query_type
    ldr r3, [r0]
    cmp r3, #QUERY_MAX
    beq do_max_query
    cmp r3, #QUERY_MIN
    beq do_min_query
    @ else fall through to AVG

do_avg_query:
    @ range_query_sum(r0=base, r1=tree_l, r2=tree_r) → r0=sum
    @ r4/r5 (user_l/r) survive because range_query_sum push/pops r4-r9.
    ldr r0, =sum_tree
    bl  range_query_sum        @ r0 = sum over [l,r]
    sub r1, r5, r4
    add r1, r1, #1             @ count = user_r - user_l + 1
    udiv r0, r0, r1            @ avg = sum / count  (integer)
    b   save_result

do_max_query:
    ldr r0, =max_tree
    bl  range_query_max        @ r0 = max over [l,r]
    b   save_result

do_min_query:
    ldr r0, =min_tree
    bl  range_query_min        @ r0 = min over [l,r]

save_result:
    ldr r1, =query_result
    str r0, [r1]
    ldr r0, =current_state
    mov r1, #STATE_SHOW_RESULT
    str r1, [r0]
    bl  debounce_delay
    b   fsm_loop

@ ============================================================
@ STATE 5: SHOW RESULT
@ Scrolls result on LED (tens digit → ones digit for two-digit values).
@ Button A → full reset back to IDLE (trees wiped).
@ Button B → new query on SAME dataset (trees preserved,
@            query params reset, go back to SEL_QUERY).
@ ============================================================
handle_show_result:
    ldr r0, =query_result
    ldr r1, [r0]
    mov r0, r1
    bl  show_number            @ one display cycle (visible ~1 sec)

    bl  poll_buttons           @ r0: 1=A, 2=B, 0=none
    cmp r0, #1
    beq show_result_reset      @ A → full reset to IDLE
    cmp r0, #2
    beq show_result_requery    @ B → re-query same dataset
    b   handle_show_result     @ neither → keep showing

show_result_reset:
    bl  init_data              @ wipes trees, resets state to STATE_IDLE
    bl  debounce_delay
    b   fsm_loop

show_result_requery:
    @ Trees and total_readings are intentionally NOT cleared.
    @ Only reset the three query-selection variables so the
    @ user starts the query picker fresh on the same data.
    ldr r0, =query_type
    mov r1, #QUERY_MAX
    str r1, [r0]
    ldr r0, =query_l
    mov r1, #0
    str r1, [r0]
    ldr r0, =query_r
    mov r1, #0
    str r1, [r0]
    ldr r0, =current_state
    mov r1, #STATE_SEL_QUERY
    str r1, [r0]
    bl  debounce_delay
    b   fsm_loop

@ ============================================================
@ ERROR HANDLERS
@ Flashes all LEDs 4 times, then returns to IDLE.
@ ============================================================
error_no_data:
error_bad_range:
    bl flash_error
    bl init_data
    b  fsm_loop

@ ============================================================
@ ============================================================
@ SUBROUTINES
@ ============================================================
@ ============================================================

@ ------------------------------------------------------------
@ init_hardware
@ Configures Button A (pin 14) and Button B (pin 23) as
@ inputs with internal pull-up resistors.
@ ------------------------------------------------------------
init_hardware:
    ldr r0, =0x50000738        @ PIN_CNF[14]
    mov r1, #0x0C              @ Input, pull-up enabled
    str r1, [r0]
    ldr r0, =0x5000075C        @ PIN_CNF[23]
    mov r1, #0x0C
    str r1, [r0]
    bx  lr

@ ------------------------------------------------------------
@ init_data
@ Fills all three trees with sentinel values, resets all
@ state variables to defaults.  current_state → STATE_IDLE.
@ ------------------------------------------------------------
init_data:
    push {r4-r9, lr}

    @ --- max_tree: leaf nodes = 0x80000000 (identity for MAX),
    @               internal nodes = 0 (will be overwritten by insert) ---
    ldr  r4, =max_tree
    ldr  r6, =0x80000000
    mov  r5, #0
    mov  r9, #(TREE_SIZE - 1)
max_init_loop:
    lsl  r7, r9, #2            @ byte offset = index × 4
    cmp  r9, #TREE_LEAVES
    blt  max_int_node          @ index < 128 → internal
    str  r6, [r4, r7]          @ leaf: MIN_INT sentinel
    b    max_next
max_int_node:
    str  r5, [r4, r7]          @ internal: 0
max_next:
    subs r9, r9, #1
    bpl  max_init_loop

    @ --- min_tree: leaf nodes = 0x7FFFFFFF, internals = 0 ---
    ldr  r4, =min_tree
    ldr  r6, =0x7FFFFFFF
    mov  r9, #(TREE_SIZE - 1)
min_init_loop:
    lsl  r7, r9, #2
    cmp  r9, #TREE_LEAVES
    blt  min_int_node
    str  r6, [r4, r7]          @ leaf: MAX_INT sentinel
    b    min_next
min_int_node:
    str  r5, [r4, r7]
min_next:
    subs r9, r9, #1
    bpl  min_init_loop

    @ --- sum_tree: all zeros ---
    ldr  r4, =sum_tree
    mov  r9, #(TREE_SIZE - 1)
sum_init_loop:
    lsl  r7, r9, #2
    str  r5, [r4, r7]
    subs r9, r9, #1
    bpl  sum_init_loop

    @ --- State variables ---
    ldr r0, =button_event
    mov r1, #0
    str r1, [r0]               @ Clear the button latch
    ldr r0, =current_state
    mov r1, #STATE_IDLE
    str r1, [r0]
    ldr r0, =total_readings
    mov r1, #0
    str r1, [r0]
    ldr r0, =query_type
    mov r1, #QUERY_MAX
    str r1, [r0]
    ldr r0, =query_l
    mov r1, #0
    str r1, [r0]
    ldr r0, =query_r
    mov r1, #0
    str r1, [r0]
    ldr r0, =query_result
    mov r1, #0
    str r1, [r0]

    pop  {r4-r9, pc}

@ ------------------------------------------------------------
@ read_temperature
@ Triggers the nRF TEMP peripheral, waits for completion,
@ returns signed Celsius in r0.
@ ------------------------------------------------------------
read_temperature:
    push {lr}
    ldr r0, =0x4000C000
    mov r1, #1
    str r1, [r0, #0x000]       @ TASKS_START
read_temp_poll:
    ldr r1, [r0, #0x100]       @ EVENTS_DATARDY
    cmp r1, #0
    beq read_temp_poll
    mov r1, #0
    str r1, [r0, #0x100]       @ Clear event
    ldr r0, [r0, #0x508]       @ TEMP register (units: 0.25 °C)
    asr r0, r0, #2             @ >> 2  →  integer Celsius
    pop  {pc}

@ ------------------------------------------------------------
@ insert_reading
@ Inserts one temperature reading into all three trees and
@ runs bubble-up on each.
@ r0 = temperature value
@ r2 = leaf index  (0 to MAX_READINGS-1)
@ Preserves r0-r3; clobbers r4-r11 internally (saved/restored).
@ ------------------------------------------------------------
insert_reading:
    push {r4-r11, lr}
    mov  r10, r0               @ save temp
    mov  r11, r2               @ save leaf index
    add  r6, r11, #TREE_LEAVES @ tree node index for this leaf

    @ ---- max_tree bubble-up ----
    ldr  r3, =max_tree
    lsl  r4, r6, #2
    str  r10, [r3, r4]         @ write temp to leaf
    mov  r5, r6
bubble_max:
    lsr  r5, r5, #1            @ move to parent
    cmp  r5, #0
    beq  bubble_max_done
    lsl  r4, r5, #1            @ left child index
    lsl  r7, r4, #2
    ldr  r8, [r3, r7]          @ left child value
    add  r4, r4, #1            @ right child index
    lsl  r7, r4, #2
    ldr  r9, [r3, r7]          @ right child value
    cmp  r8, r9
    bgt  bmax_take_left
    mov  r8, r9                @ r8 = max(left, right)
bmax_take_left:
    lsl  r7, r5, #2
    str  r8, [r3, r7]          @ store max into parent
    b    bubble_max
bubble_max_done:

    @ ---- min_tree bubble-up ----
    ldr  r3, =min_tree
    lsl  r4, r6, #2
    str  r10, [r3, r4]
    mov  r5, r6
bubble_min:
    lsr  r5, r5, #1
    cmp  r5, #0
    beq  bubble_min_done
    lsl  r4, r5, #1
    lsl  r7, r4, #2
    ldr  r8, [r3, r7]
    add  r4, r4, #1
    lsl  r7, r4, #2
    ldr  r9, [r3, r7]
    cmp  r8, r9
    blt  bmin_take_left
    mov  r8, r9                @ r8 = min(left, right)
bmin_take_left:
    lsl  r7, r5, #2
    str  r8, [r3, r7]
    b    bubble_min
bubble_min_done:

    @ ---- sum_tree bubble-up ----
    ldr  r3, =sum_tree
    lsl  r4, r6, #2
    str  r10, [r3, r4]
    mov  r5, r6
bubble_sum:
    lsr  r5, r5, #1
    cmp  r5, #0
    beq  bubble_sum_done
    lsl  r4, r5, #1
    lsl  r7, r4, #2
    ldr  r8, [r3, r7]
    add  r4, r4, #1
    lsl  r7, r4, #2
    ldr  r9, [r3, r7]
    add  r8, r8, r9            @ r8 = left + right
    lsl  r7, r5, #2
    str  r8, [r3, r7]
    b    bubble_sum
bubble_sum_done:

    pop  {r4-r11, pc}

@ ------------------------------------------------------------
@ range_query_max
@ Standard iterative segment-tree range max.
@ r0 = tree base address
@ r1 = tree_l  (inclusive leaf-node index = TREE_LEAVES + user_l)
@ r2 = tree_r  (inclusive leaf-node index = TREE_LEAVES + user_r)
@ Returns: r0 = max value in [l, r]
@ ------------------------------------------------------------
range_query_max:
    push {r4-r9, lr}
    mov  r4, r0                @ tree base
    mov  r5, r1                @ l
    mov  r6, r2                @ r
    ldr  r7, =0x80000000       @ result = MIN_INT
rqmax_loop:
    cmp  r5, r6
    bgt  rqmax_done
    tst  r5, #1                @ l is odd → right child → include
    beq  rqmax_skip_l
    lsl  r8, r5, #2
    ldr  r9, [r4, r8]
    cmp  r9, r7
    blt  rqmax_l_no_update
    mov  r7, r9
rqmax_l_no_update:
    add  r5, r5, #1
rqmax_skip_l:
    tst  r6, #1                @ r is even → left child → include
    bne  rqmax_skip_r
    lsl  r8, r6, #2
    ldr  r9, [r4, r8]
    cmp  r9, r7
    blt  rqmax_r_no_update
    mov  r7, r9
rqmax_r_no_update:
    sub  r6, r6, #1
rqmax_skip_r:
    lsr  r5, r5, #1
    lsr  r6, r6, #1
    b    rqmax_loop
rqmax_done:
    mov  r0, r7
    pop  {r4-r9, pc}

@ ------------------------------------------------------------
@ range_query_min
@ r0=base, r1=tree_l, r2=tree_r  →  r0 = min value
@ ------------------------------------------------------------
range_query_min:
    push {r4-r9, lr}
    mov  r4, r0
    mov  r5, r1
    mov  r6, r2
    ldr  r7, =0x7FFFFFFF       @ result = MAX_INT
rqmin_loop:
    cmp  r5, r6
    bgt  rqmin_done
    tst  r5, #1
    beq  rqmin_skip_l
    lsl  r8, r5, #2
    ldr  r9, [r4, r8]
    cmp  r9, r7
    bgt  rqmin_l_no_update
    mov  r7, r9
rqmin_l_no_update:
    add  r5, r5, #1
rqmin_skip_l:
    tst  r6, #1
    bne  rqmin_skip_r
    lsl  r8, r6, #2
    ldr  r9, [r4, r8]
    cmp  r9, r7
    bgt  rqmin_r_no_update
    mov  r7, r9
rqmin_r_no_update:
    sub  r6, r6, #1
rqmin_skip_r:
    lsr  r5, r5, #1
    lsr  r6, r6, #1
    b    rqmin_loop
rqmin_done:
    mov  r0, r7
    pop  {r4-r9, pc}

@ ------------------------------------------------------------
@ range_query_sum
@ r0=base, r1=tree_l, r2=tree_r  →  r0 = sum of values
@ ------------------------------------------------------------
range_query_sum:
    push {r4-r9, lr}
    mov  r4, r0
    mov  r5, r1
    mov  r6, r2
    mov  r7, #0                @ running sum
rqsum_loop:
    cmp  r5, r6
    bgt  rqsum_done
    tst  r5, #1
    beq  rqsum_skip_l
    lsl  r8, r5, #2
    ldr  r9, [r4, r8]
    add  r7, r7, r9
    add  r5, r5, #1
rqsum_skip_l:
    tst  r6, #1
    bne  rqsum_skip_r
    lsl  r8, r6, #2
    ldr  r9, [r4, r8]
    add  r7, r7, r9
    sub  r6, r6, #1
rqsum_skip_r:
    lsr  r5, r5, #1
    lsr  r6, r6, #1
    b    rqsum_loop
rqsum_done:
    mov  r0, r7
    pop  {r4-r9, pc}

@ ------------------------------------------------------------
@ poll_buttons (Event-Driven)
@ 1. Checks RAM latch. 2. Checks Raw Pins.
@ Returns: r0 = 1 (A), 2 (B), 0 (none)
@ ------------------------------------------------------------
poll_buttons:
    @ 1. Check Latch First
    ldr  r1, =button_event
    ldr  r0, [r1]
    cmp  r0, #0
    bne  pb_consume_latch

    @ 2. If Latch is empty, Check Raw Pins
    ldr  r1, =0x50000000
    ldr  r2, [r1, #0x510]
    
    tst  r2, #(1 << 14)
    beq  pb_raw_a
    
    tst  r2, #(1 << 23)
    beq  pb_raw_b
    
    mov  r0, #0
    bx   lr

pb_raw_a:
    mov  r0, #1
    bx   lr

pb_raw_b:
    mov  r0, #2
    bx   lr

pb_consume_latch:
    mov  r2, #0
    str  r2, [r1]               @ Clear latch so it only fires once!
    bx   lr

@ ------------------------------------------------------------
@ poll_button_a (Event-Driven Wrapper)
@ ------------------------------------------------------------
poll_button_a:
    push {lr}
    bl   poll_buttons           @ Run the master polling logic
    cmp  r0, #1                 @ Did it return Button A?
    ite  eq
    moveq r0, #1
    movne r0, #0
    pop  {pc}

@ ------------------------------------------------------------
@ interval_wait_or_button
@ Busy-waits for TEMP_INTERVAL counts.
@ Checks Button A every 1024 counts for responsiveness.
@ Returns: r0 = 1 if A pressed early, 0 on natural timeout.
@ ------------------------------------------------------------
interval_wait_or_button:
    push {r4, lr}
    ldr  r4, =TEMP_INTERVAL
iwob_loop:
    subs r4, r4, #1
    beq  iwob_timeout
    tst  r4, #0xFF   @ check every 1024 counts
    bne  iwob_loop
    bl   poll_button_a
    cmp  r0, #1
    bne  iwob_loop
    bl   debounce_delay
    mov  r0, #1
    pop  {r4, pc}
iwob_timeout:
    mov  r0, #0
    pop  {r4, pc}

@ ------------------------------------------------------------
@ debounce_delay  (~250 ms busy-wait)
@ ------------------------------------------------------------
debounce_delay:
    ldr r0, =0x400000
dbd_loop:
    subs r0, r0, #1
    bne  dbd_loop
    bx   lr

@ ------------------------------------------------------------
@ delay_loop (Smart Polling Version)
@ Acts as a standard delay, but checks pins periodically.
@ If a button is pressed, it latches the event to RAM and ABORTS.
@ ------------------------------------------------------------
delay_loop:
    push {r1-r4, lr}
    mov  r4, r0                 @ r4 = delay count
    ldr  r1, =0x50000000        @ GPIO Base
dl_spin:
    subs r4, r4, #1
    beq  dl_done
    tst  r4, #0xFF              @ Check pins every 256 cycles
    bne  dl_spin

    @ Read GPIO IN
    ldr  r2, [r1, #0x510]
    
    @ Check A (Pin 14)
    tst  r2, #(1 << 14)
    beq  dl_latch_a

    @ Check B (Pin 23)
    tst  r2, #(1 << 23)
    beq  dl_latch_b

    b    dl_spin                @ Neither pressed, continue delay

dl_latch_a:
    ldr  r3, =button_event
    mov  r2, #1
    str  r2, [r3]
    b    dl_done                @ Button A caught! ABORT DELAY early!

dl_latch_b:
    ldr  r3, =button_event
    mov  r2, #2
    str  r2, [r3]
    @ Fall through to done

dl_done:
    pop  {r1-r4, pc}
@ ============================================================
@ ============================================================
@ DISPLAY SUBROUTINES
@ ============================================================
@ ============================================================
@
@ Hardware note (nRF51 / micro:bit matrix):
@   Row HIGH  + Column LOW  = LED ON
@   Row LOW   OR column HIGH = LED OFF
@
@ write_row_pins(r0)   : bit i = 1 → row i HIGH  (1 = row active)
@ write_column_pins(r0): bit i = 1 → col pin HIGH (HIGH = LED OFF!)
@
@ Therefore, to display a font pattern where 1 = LED on:
@   col_arg = ~font_pattern & 0b11111   (mvn + mask)
@ ============================================================

@ ------------------------------------------------------------
@ show_idle_pulse
@ Pulses the center LED (row 2, col 2) ~80 times.
@ Used in IDLE and SHOW_RESULT wait loops.
@ ------------------------------------------------------------
show_idle_pulse:
    push {r4, lr}
    ldr  r4, =80
idle_pulse_outer:
    mov  r0, #0b00100          @ row 2 high
    bl   write_row_pins
    mov  r0, #(0b11111 ^ 0b00100)   @ 0b11011: col 2 LOW = LED ON
    bl   write_column_pins
    ldr  r0, =500
    bl   delay_loop
    @ Row off
    mov  r0, #0
    bl   write_row_pins
    ldr  r0, =500
    bl   delay_loop
    subs r4, r4, #1
    bne  idle_pulse_outer
    @ Blank display
    mov  r0, #0
    bl   write_row_pins
    mov  r0, #0b11111
    bl   write_column_pins
    pop  {r4, pc}

@ ------------------------------------------------------------
@ blink_confirm
@ Flashes all 25 LEDs briefly (reading-taken indicator).
@ ------------------------------------------------------------
blink_confirm:
    push {r4, lr}
    ldr  r4, =40
blink_on:
    mov  r0, #0b11111
    bl   write_row_pins
    mov  r0, #0                @ all cols LOW = all LEDs ON
    bl   write_column_pins
    ldr  r0, =300
    bl   delay_loop
    mov  r0, #0
    bl   write_row_pins
    ldr  r0, =300
    bl   delay_loop
    subs r4, r4, #1
    bne  blink_on
    @ Blank
    mov  r0, #0
    bl   write_row_pins
    mov  r0, #0b11111   
    bl   write_column_pins
    pop  {r4, pc}

@ ------------------------------------------------------------
@ show_digit
@ Displays a single digit (0-9) using row-multiplexing.
@ r0 = digit  (0-9; clamped internally if out of range)
@ Duration: 300 full-frame passes ≈ ~1 second visible.
@ ------------------------------------------------------------
show_digit:
    push {r4-r9, lr}
    mov  r4, r0

    @ Clamp to [0, 9]
    cmp  r4, #0
    it   lt               @ IF Less Than...
    movlt r4, #0          @ THEN move 0
    
    cmp  r4, #9
    it   gt               @ IF Greater Than...
    movgt r4, #9          @ THEN move 9

    @ Font table offset = digit × 20 bytes (5 rows × 4 bytes)
    mov  r5, #20
    mul  r5, r4, r5            @ r5 = offset
    ldr  r6, =font_table
    add  r6, r6, r5            @ r6 → this digit's row data

    ldr  r4, =2000              @ multiplex pass count
show_digit_outer:
    mov  r7, #0                @ row index 0..4
show_digit_row:
    cmp  r7, #5
    bge  show_digit_row_done

    @ 1. SET COLUMNS FIRST (This permanently fixes the dim ghosting!)
    ldr  r9, [r6, r7, lsl #2]  
    mvn  r0, r9
    and  r0, r0, #0b11111      
    bl   write_column_pins

    @ 2. NOW ACTIVATE THE ROW
    mov  r8, #1
    lsl  r8, r8, r7
    mov  r0, r8
    bl   write_row_pins

    @ 3. HOLD THE IMAGE
    ldr  r0, =300
    bl   delay_loop

    @ 4. DEACTIVATE ROW BEFORE LOOPING
    mov  r0, #0
    bl   write_row_pins

    add  r7, r7, #1
    b    show_digit_row

show_digit_row_done:
    subs r4, r4, #1
    bne  show_digit_outer

    @ Blank display
    mov  r0, #0
    bl   write_row_pins
    mov  r0, #0b11111
    bl   write_column_pins
    pop  {r4-r9, pc}

@ ------------------------------------------------------------
@ split_digits
@ r0 = value  →  r1 = tens digit,  r2 = ones digit
@ ------------------------------------------------------------
split_digits:
    push {r3, r4, lr}
    mov  r3, #10
    udiv r1, r0, r3            @ r1 = value / 10  (tens)
    mul  r4, r1, r3            @ r4 = tens * 10
    sub  r2, r0, r4            @ r2 = value - (tens*10)  (ones)
    pop  {r3, r4, pc}

@ ------------------------------------------------------------
@ ------------------------------------------------------------
@ ------------------------------------------------------------
@ show_number
@ Single digits are held static. Two digits scroll beautifully
@ from right to left like a digital marquee.
@ ------------------------------------------------------------
show_number:
    push {r4, lr}
    mov  r4, r0

    @ Clamp to [0, 99]
    cmp  r4, #0
    it   lt
    movlt r4, #0
    cmp  r4, #99
    it   gt
    movgt r4, #99

    cmp  r4, #10
    blt  show_num_single

    @ Two-digit marquee scroll
    mov  r0, r4
    bl   scroll_two_digits
    pop  {r4, pc}

show_num_single:
    mov  r0, r4
    bl   show_digit
    pop  {r4, pc}

@ ------------------------------------------------------------
@ scroll_two_digits (The Marquee Engine)
@ Builds an invisible 16-bit wide row: 
@ [5-bit Blank] [5-bit Tens] [1-bit Gap] [5-bit Ones]
@ Then slides a 5-bit viewing window across it!
@ ------------------------------------------------------------
scroll_two_digits:
    push {r4-r10, lr}
    bl   split_digits          @ r1 = Tens, r2 = Ones

    @ 1. Calculate Font Memory Addresses
    mov  r3, #20
    mul  r4, r1, r3
    ldr  r9, =font_table
    add  r4, r9, r4            @ r4 = Memory address of Tens
    
    mul  r5, r2, r3
    ldr  r9, =font_table
    add  r5, r9, r5            @ r5 = Memory address of Ones

    @ 2. The Scroll Offset Loop (Slide window from 0 to 16)
    mov  r6, #0                @ r6 = 'S' (Scroll Offset)
scroll_frame_loop:
    ldr  r7, =600             @ r7 = Frame Hold (Decrease to scroll faster, increase for slower)
hold_frame_loop:
    mov  r8, #0                @ r8 = Row Index (0 to 4)

scroll_row_loop:
    cmp  r8, #5
    bge  scroll_row_done

    @ A. Load font data for both digits for this specific row
    ldr  r9, [r4, r8, lsl #2]  @ Load Tens row
    ldr  r10, [r5, r8, lsl #2] @ Load Ones row

    @ B. Build the invisible wide image in r9
    lsl  r9, r9, #5            @ Push Tens to the right (starts off-screen)
    lsl  r10, r10, #11         @ Push Ones further right (creates a 1-bit gap between them)
    orr  r9, r9, r10           @ Combine them together!

    @ C. Apply the Sliding Window
    lsr  r9, r9, r6            @ Shift the wide image right by 'S' columns
    and  r9, r9, #0b11111      @ Mask out everything except the 5 columns currently on screen

    @ D. Write to Columns (Invert the bits for active-low LEDs)
    mvn  r0, r9
    and  r0, r0, #0b11111
    bl   write_column_pins

    @ E. Activate the Row
    mov  r9, #1
    lsl  r0, r9, r8
    bl   write_row_pins

    @ F. Hardware Delay (Hold the LEDs on)
    ldr  r0, =300
    bl   delay_loop

    @ G. Turn Row Off (Prevent Ghosting)
    mov  r0, #0
    bl   write_row_pins

    add  r8, r8, #1
    b    scroll_row_loop

scroll_row_done:
    @ Repeat the same frame to keep it visible to the human eye
    subs r7, r7, #1
    bne  hold_frame_loop

    @ Advance the scroll window by 1 column
    add  r6, r6, #1
    cmp  r6, #17               @ 17 total frames to slide entirely on and off screen
    bne  scroll_frame_loop

    @ Huge pause at the end of the scroll before the FSM loops it
    ldr  r0, =4000000
    bl   delay_loop

    pop  {r4-r10, pc}
@ ------------------------------------------------------------
@ flash_error
@ Flashes all 25 LEDs 4 times to signal an error condition.
@ ------------------------------------------------------------
flash_error:
    push {r4, lr}
    mov  r4, #4
flash_err_on:
    mov  r0, #0b11111
    bl   write_row_pins
    mov  r0, #0                @ all cols LOW = all LEDs ON
    bl   write_column_pins
    ldr  r0, =700000
    bl   delay_loop
    mov  r0, #0
    bl   write_row_pins
    mov  r0, #0b11111
    bl   write_column_pins
    ldr  r0, =700000
    bl   delay_loop
    subs r4, r4, #1
    bne  flash_err_on
    pop  {r4, pc}

@ ============================================================
@ ============================================================
@ ============================================================
@ FONT TABLE (Simple Block Style, Corrected Bit Mapping)
@ Bit layout per row:  bit4=col4(Right) .. bit0=col0(Left)
@ ============================================================
font_table:
    @ --- 0 --- 
    .word 0b11111
    .word 0b10001
    .word 0b10001
    .word 0b10001
    .word 0b11111
    @ --- 1 --- 
    .word 0b00100
    .word 0b00100
    .word 0b00100
    .word 0b00100
    .word 0b00100
    @ --- 2 --- 
    .word 0b11111  
    .word 0b10000  @ Right LED only
    .word 0b11111  
    .word 0b00001  @ Left LED only
    .word 0b11111  
    @ --- 3 --- 
    .word 0b11111  
    .word 0b10000  @ Right LED only
    .word 0b11111  
    .word 0b10000  @ Right LED only
    .word 0b11111  
    @ --- 4 --- 
    .word 0b10001
    .word 0b10001
    .word 0b11111
    .word 0b10000  @ Right LED only
    .word 0b10000  @ Right LED only
    @ --- 5 --- 
    .word 0b11111
    .word 0b00001  @ Left LED only
    .word 0b11111
    .word 0b10000  @ Right LED only
    .word 0b11111
    @ --- 6 --- 
    .word 0b11111
    .word 0b00001  @ Left LED only
    .word 0b11111
    .word 0b10001
    .word 0b11111
    @ --- 7 --- 
    .word 0b11111
    .word 0b10000  @ Right LED only
    .word 0b10000  @ Right LED only
    .word 0b10000  @ Right LED only
    .word 0b10000  @ Right LED only
    @ --- 8 --- 
    .word 0b11111
    .word 0b10001
    .word 0b11111
    .word 0b10001
    .word 0b11111
    @ --- 9 --- 
    .word 0b11111
    .word 0b10001
    .word 0b11111
    .word 0b10000  @ Right LED only
    .word 0b11111