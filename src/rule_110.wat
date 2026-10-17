;; The Rule 110 Cellular Automaton has its name because its update rule corresponds 
;; to the binary representation of the number 110 in binary form, 01101110.
;;
;; The rule is a one-dimensional cellular automaton that is updated based on the 
;; two immediate neighbors of each cell.
;;
;; Neighborhood | 111 | 110 | 101 | 100 | 011 | 010 | 001 | 000 |
;; -------------|-----|-----|-----|-----|-----|-----|-----|-----|
;; New Cell     |  0  |  1  |  1  |  0  |  1  |  1  |  1  |  0  |

(module
  (memory (export "mem") 1)  ;; allocate 1 page of memory (64KiB)

  ;; We initialise the memory with a random sequence of cells. Each cell can be 
  ;; either 0 or 1.

  ;; Base address in memory where the cells will be stored.
  (global $cells_start i32 (i32.const 0))  ;; starting at address 0

  ;; Address in memory where the first buffer stops. (exclusive)
  (global $cells_stop i32 (i32.const 24))  ;; for example, 24 cells

  ;; Base address in memory where the auxiliary cells will be stored.
  (global $aux_cells_start i32 (i32.const 24))

  ;; Address in memory where the second buffer stops.
  (global $aux_cells_stop i32 (i32.const 48))
  
  ;; WebAssembly doesn't count with a random number generator, so we will implement
  ;; one ourselves using the Xorshift algorithm.

  ;; A global variable to store the state of the random number generator.
  (global $rng_state (mut i32) (i32.const 127))  ;; initial seed must be non-zero

  ;; We can allow the JavaScript side to set the initial seed if needed.
  (func $set_seed (param $seed i32)
    ;; The seed cannot be zero.
    
    ;; Where we are using the "ternary operations" pattern in WebAssembly:
    ;;    select(cond, a, b) is equivalent to (cond ? a : b) in C-like languages.

    ;; options
    i32.const 127         ;; a: used when cond != 0  (i.e. seed == 0)
    local.get $seed       ;; b: used when cond == 0  (i.e. seed != 0)

    ;; cond
    local.get $seed
    i32.eqz               ;; pushes 1 onto the stack if seed == 0 and 0 otherwise     
    
    select                ;; cond!=0 → a (127); cond==0 → b (seed)

    global.set $rng_state
  )

  ;; Xorshift random number generator algorithm works by applying a series of 
  ;; bitwise XOR and shift operations to the internal state.
  ;;     x = rng_state
  ;;     x ^= x << 13;
  ;;     x ^= x >> 17;
  ;;     x ^= x << 5;
  ;;     return x;
  (func $rand (result i32)
    ;; Any local variable must be defined at the beginning of the function.
    (local $x i32)
    
    ;; x = rng_state
    global.get $rng_state
    local.tee $x  ;; copy the top of the stack to local $x without popping it.
  
    ;; x ^= x << 13
    local.get $x
    i32.const 13
    i32.shl
    i32.xor
    local.tee $x  ;; update local $x with the new value without popping it.

    ;; x ^= x >>> 17
    local.get $x
    i32.const 17
    i32.shr_u
    i32.xor
    local.tee $x

    ;; x ^= x << 5
    local.get $x
    i32.const 5
    i32.shl
    i32.xor
    local.tee $x

    ;; update the global state with the new value
    local.get $x
    global.set $rng_state

    ;; There is still one copy of the new random number on the stack, which will
    ;; be returned as the result of the function.
  )

  (func $init_cells
    ;; Any local variables must be defined at the beginning of the function.
    (local $idx i32) ;; default value: 0 

    (loop $fill
      ;; address = cells_start + idx
      global.get $cells_start
      local.get $idx
      i32.add

      ;; fill = rand() & 1
      call $rand
      i32.const 1
      i32.and

      ;; store a single byte
      i32.store8
      
      ;; idx = idx + 1
      local.get $idx
      i32.const 1
      i32.add
      local.set $idx

      ;; continue the loop if idx < cells_stop
      local.get $idx
      global.get $cells_stop
      i32.lt_u
      br_if $fill

      ;; nothing to return here.
    )
  )

  (func $new_cell (param $left i32) (param $centre i32) (param $right i32) (result i32)
    ;; A new cell is given by the stat of its neighbours.
    ;;    index = (left << 2) | (centre << 1) | right
    ;;    new_cell = (110 >> index) & 1
    ;; or, in a more compact form:
    ;;    new_cell = (110 >> ((left << 2) | (centre << 1) | right)) & 1

    ;; Since WebAssembly is a stack-based VM, we first push the outmost parameter
    ;; onto the stack. In this case, that is the 1 on the right of the bitwise 
    ;; AND operation.
    i32.const 1

    ;; Next we push the elements of the first bracket starting by the constant.
    i32.const 110

    ;; Start the computation of the index.

    ;; (left << 2)
    local.get $left
    i32.const 2
    i32.shl

    ;; (centre << 1)
    local.get $centre
    i32.const 1
    i32.shl

    ;; right
    local.get $right

    ;; Combine them to form the index
    i32.or
    i32.or

    ;; Shift 110 right by the index using "shift right unsigned" (filling with zeros)
    i32.shr_u

    ;; AND with 1 to get the new cell value
    i32.and
  )

  (func $next
    (local $idx i32)
    (local $cell_idx i32)
    (local $buff_idx i32)

    (local $stop i32)

    ;; Hold the cell values.
    (local $left i32)
    (local $centre i32)
    (local $right i32)

    ;; Loop counter starts at 1 because the first cell is processed separately.
    i32.const 1
    local.set $idx

    ;; Like the first cell, the last cell is processed separately.
    global.get $cells_stop
    i32.const 1
    i32.sub
    local.set $stop

    ;; Loop over the cells from 1 to N-1.
    (loop $main_loop
      ;; --- Update the indices ---

      ;; cell_idx = base + idx
      global.get $cells_start
      local.get $idx
      i32.add
      local.set $cell_idx

      ;; aux_cells_idx = base_aux +  idx
      global.get $aux_cells_start
      local.get $idx
      i32.add
      local.set $buff_idx

      ;; --- Fetch the cell values ---
      ;; left = cells[cell_idx - 1]
      local.get $cell_idx
      i32.const 1
      i32.sub
      i32.load8_u
      local.set $left

      ;; centre = cells[cell_idx]
      local.get $cell_idx
      i32.load8_u
      local.set $centre

      ;; right = cells[cell_idx + 1]
      local.get $cell_idx
      i32.const 1
      i32.add
      i32.load8_u
      local.set $right

      ;; --- Compute new value ans store in the buffer --- 
      local.get $buff_idx
      ;; compute the new value
      local.get $left
      local.get $centre
      local.get $right
      call $new_cell
      ;; Store it respective buffer
      i32.store8
      
      ;; --- End of main loop iteration ---
      ;; Increment the centre index for the next iteration
      local.get $idx
      i32.const 1
      i32.add
      local.tee $idx  ;; copy without popping

      ;; Check if idx reached the stop condition
      local.get $stop
      i32.lt_s
      br_if $main_loop
    )

      ;; -- Handle first cell using toroidal indexing ---

      ;; Fetch values
      ;; left = cells[N-1] (last cell)
      global.get $cells_stop
      i32.const 1
      i32.sub
      i32.load8_u
      local.set $left

      ;; centre = cells[0]
      global.get $cells_start
      i32.load8_u
      local.set $centre

      ;; right = cells[1]
      global.get $cells_start
      i32.const 1
      i32.add
      i32.load8_u
      local.set $right

      ;; --- Compute and store on the buffer ---
      global.get $aux_cells_start
      ;; compute new value
      local.get $left
      local.get $centre
      local.get $right
      call $new_cell
      ;; Store it in the first cell
      i32.store8

      ;; -- Handle last cell using toroidal indexing ---
      
      ;; Fetch values
      ;; left = cells[N-2]  (second last cell)
      global.get $cells_stop
      i32.const 2
      i32.sub
      i32.load8_u
      local.set $left

      ;; centre = cells[N-1] (last cell)
      global.get $cells_stop
      i32.const 1
      i32.sub
      i32.load8_u
      local.set $centre

      ;; right = cells[first cell]
      global.get $cells_start
      i32.load8_u
      local.set $right

      ;; --- Compute and store on the buffer for the last cell ---
      global.get $aux_cells_stop
      i32.const 1
      i32.sub
      ;; compute new value
      local.get $left
      local.get $centre
      local.get $right
      call $new_cell
      ;; Store it in the last cell
      i32.store8
  )

  (func $copy_from_buffer
    (local $idx i32)

    (loop $main_loop
      ;; cells[idx] = buff[idx]
      global.get $cells_start
      local.get $idx
      i32.add
      ;; fetch value from buffer
      global.get $aux_cells_start
      local.get $idx
      i32.add
      i32.load8_u
      ;; store it in the cells array
      i32.store8

      ;; Increment idx
      local.get $idx
      i32.const 1
      i32.add
      local.tee $idx  ;; copy without popping

      ;; Check if idx reached the stop condition
      global.get $cells_stop
      i32.lt_s
      br_if $main_loop
    )
  )

  (func $next_config
    call $next
    call $copy_from_buffer
  )
  
  (export "rand" (func $rand))
  (export "set_seed" (func $set_seed))
  (export "init_cells" (func $init_cells))
  (export "next_config" (func $next_config))
)