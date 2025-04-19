/*
 * Copyright (C) 2024 David Guillen Fandos <david@davidgf.net>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */

// Direct Saver payload.
// Provides handlers to read and write save data blocks.
// Requires low-level access to the save file (allocated contiguously).
//
// Handlers assume a valid stack with some reasonable size (~64 bytes)
// and certain tolerance for disabling interrupts (for a few cycles at a time).

#include "gba_regs.h"

#define SAFE_OP_ROUTINE_SIZE    12   // Number of insts (32 bit insts)
#define SAFE_OP_INST_OFF         5   // Instruction number (from 0) in the routine

// Jump table in ARM mode to simplify instruction sizes.
.section    .directsave, "ax"
.align 4
.arm

.global sc_issdhc
.global sc_rca

// Header. Contains jump entry point to avoid relocations.
b ds_entrypoint

// Fields (to be filled by the loader/patcher)
sector_number:
  .word 0x0                  // SD card sector number (LBA)
memory_size:
  .word 0x0                  // Memory size (in bytes) of the flash/eeprom device (512, 8192, 32768, 65536, 131072)
sd_mutex:
  .word 0x0                  // SD access mutex (set to one when there's an ongoing operation).

// SD card driver params.
drv_issdhc:
  .word 0x0
drv_rca:
  .word 0x0

// Necessary handlers for the SC driver
sc_issdhc:
  ldr r0, drv_issdhc
  bx lr

sc_rca:
  ldr r0, drv_rca
  bx lr


// Receives a function call, the call number is stored in r7
ds_entrypoint:
  push {lr}

  // Set mutex.
  mov r3, $1
  bl set_clear_mutex

  adr r3, ds_table
  mov lr, pc
  add pc, r3, r7, lsl #2

  // Clear mutex.
  mov r3, $0
  bl set_clear_mutex

  pop {lr}
  bx lr

ds_table:
  b ds_read_eeprom
  b ds_write_eeprom
  b ds_read_flash
  b ds_write_sector_flash
  b ds_erase_chip_flash
  b ds_erase_sector_flash


set_clear_mutex:
  push {r0, r1, r2}

  // Set SDRAM as read write
  mov r0, $0x0A000000
  ldr r1, =0xA55A
  mov r2, $0x5

  strh r1, [r0, #-2]
  strh r1, [r0, #-2]
  strh r2, [r0, #-2]
  strh r2, [r0, #-2]

  // Update mutex values
  str r3, sd_mutex

  // Set SDRAM as read only
  mov r2, $0x1
  strh r1, [r0, #-2]
  strh r1, [r0, #-2]
  strh r2, [r0, #-2]
  strh r2, [r0, #-2]

  pop {r0, r1, r2}
  bx lr

// Reads the requested data into the buffer (in WRAM). We use SRAM as a temp
// buffer to read sectors.
// r0: Destination buffer (in WRAM)
// r1: Offset in bytes
// r2: Number of bytes to read and copy.
ds_read_flash:
  push {r4, lr}

  add r4, r1, r2             // Calculate the last byte offset (start + size - 1)
  sub r4, $1
  lsr r4, r4, #9             // Calculate the last block (the block num for the last byte)

  lsr r3, r1, #9             // First block to read (offset / 512)
  lsl r1, r1, #23            // Offset within the first block (offset & 511)
  lsr r1, r1, #23

  push {r0, r1, r2}          // Save r0 (dest), r1 (offset), r2 (count)

  mov r0, $0x0E000000        // Temp SRAM buffer

  ldr r1, sector_number
  add r1, r3                 // Calculate absolute sector by adding the base sector num

  sub r2, r4, r3             // Number of blocks to read
  add r2, $1                 // (last - first + 1)

  bl sdcard_read_blocks
  pop  {r0, r1, r2}

  // Copy data from SRAM to the destination buffer, skip first r1 bytes.
  mov r3, $0x0E000000
  add r1, r1, r3

  1:
    ldrb r3, [r1], #1
    strb r3, [r0], #1
    subs r2, $1
    bne 1b

  pop {r4, lr}
  bx lr


// Writes a full sector (4KBytes) to the flash device. This was previously erased.
// r0: Source buffer (in WRAM)
// r1: Sector number to write (in 4KB blocks)
ds_write_sector_flash:
  push {lr}

  ldr r2, memory_size
  lsr r2, #9                 // Maximum number of 512 byte blocks of memory.
  sub r2, $1                 // Assuming the block count is power of two, get K-1

  lsl r1, #3                 // Scale flash sector num to 512b blocks (multiply by 4096/512)
  and r1, r2                 // Modulo operation (power of two), to limit sector count.

  ldr r2, sector_number
  add r1, r2                 // Calculate absolute sector by adding the base sector num
  mov r2, $8                 // Reads 8 blocks (512byte each), so 4KiB

  bl sdcard_write_blocks

  pop {lr}
  bx lr


// Writes the whole chip to ones.
ds_erase_chip_flash:
  push {lr}

  // Fill the SRAM with 0xFF so we can write ones.
  mov r0, $0x0E000000
  mov r1, $(64*1024 / 4)
  mov r2, $0xFF
  1:
    strb r2, [r0], #1
    strb r2, [r0], #1
    strb r2, [r0], #1
    strb r2, [r0], #1
    subs r1, $1
    bne 1b

  mov r0, $0x0E000000

  ldr r1, sector_number

  ldr r2, memory_size
  lsr r2, #9       // Bytes to block count

  bl sdcard_write_blocks

  pop {lr}
  bx lr


// Erases a 4KiB sector in flash
// r0: sector number to erase
ds_erase_sector_flash:
  push {lr}

  // Fill 4KB in SRAM with 0xFF so we can write ones.
  mov r3, $0x0E000000
  mov r1, $(4*1024 / 4)
  mov r2, $0xFF
  1:
    strb r2, [r3], #1
    strb r2, [r3], #1
    strb r2, [r3], #1
    strb r2, [r3], #1
    subs r1, $1
    bne 1b

  ldr r2, memory_size
  lsr r2, #9                 // Maximum number of 512 byte blocks of memory.
  sub r2, $1                 // Assuming the block count is power of two, get K-1

  lsl r0, #3                 // Flash sectors to SD sectors scaling
  and r0, r2                 // Mask/modulo to ensure we do not go out

  ldr r1, sector_number
  add r1, r0                 // Base block to write

  mov r2, $(4096 / 512)      // Number of blocks to write
  mov r0, $0x0E000000        // Source address

  bl sdcard_write_blocks

  pop {lr}
  bx lr

// This actually does read from SRAM, for speed. Data is already loaded by the loader.
// r0 buffer pointer to write or read data.
// r1 block number (blocks are 8 bytes long)
ds_read_eeprom:
  ldr r2, memory_size
  lsr r2, #3                 // Max number of EEPROM blocks

  cmp r1, r2
  movhs r0, $~0              // Return -1 if the block number exceeds the maximum
  bxhs lr

  // Actually read from SRAM into the user buffer
  mov r2, $0x0E000000
  lsl r1, #3                 // Block to byte offset

  add r2, r2, r1             // Address of the desired first byte
  add r2, r2, #7             // Start from the MSB

  .rept 8
    ldrb r3, [r2], #-1       // Read the byte from SRAM
    strb r3, [r0], #1        // Write byte to user buffer
  .endr

  mov r0, $0
  bx lr


// Updates the SRAM cache/copy and flushes the affected block to SD
// r0 buffer pointer to write or read data.
// r1 block number (blocks are 8 bytes long)
ds_write_eeprom:
  ldr r2, memory_size
  lsr r2, #3                 // Max number of EEPROM blocks

  cmp r1, r2
  movhs r0, $~0              // Return -1 if the block number exceeds the maximum
  bxhs lr

  push {r4, lr}
  mov r4, r1

  // We overwrite the SRAM buffer with the user provided buffer
  lsl r1, #3                 // Block to byte offset

  mov r2, $0x0E000000        // Load the SRAM base (0x0E000000)
  add r2, r2, r1             // Address of the desired byte
  add r2, r2, #7             // Write in inverse order (MSB first)

  .rept 8
    ldrb r3, [r0], #1        // Read byte from buffer
    strb r3, [r2], #-1       // Write the byte
  .endr

  // Now proceed to flush the updated block to SD card.
  lsr r1, r4, #6             // Calculate the 512-byte block number to overwrite
  mov r0, $0x0E000000        // Base SRAM address
  add r0, r0, r1, lsl #9     // SRAM base address to use as input ( (blk >> 6) << 9 )
  mov r2, $1                 // One block

  ldr r3, sector_number
  add r1, r3                 // Calculate absolute sector by adding the base sector num

  bl sdcard_write_blocks

  pop {r4, lr}
  bx lr


// Reimplementation of supercard_io.S routines, with the following caveats:
// Run code from the stack, disable interrupts during SD reg access and
// remap ROM when interrupts are enabled.

#define SC_MIRROR_BASE_8         0x08000000

// Used to perform writes (but also reads?) to the bus
#define SC_WRITE_REGISTER_8     (SC_MIRROR_BASE_8 + 0x01000000)
// Used to poll for reads (can be slow)
#define SC_READ_REGISTER_16     (SC_MIRROR_BASE_8 + 0x01100000)
// Command interface (bit 7 and 0)
#define SC_RDWR_COMMAND         (SC_MIRROR_BASE_8 + 0x01800000)

#define SD_DATA0                   0x0100

#define SD_ERR_READTIMEOUT             10
#define SD_ERR_WRITETIMEOUT            11
#define CMD_WAIT_DATA            0x400000     // Aprox ~1s as data timeout


// Some registers are fixed values, set on function entry for speed.
// r7 must contain REG_IMG address
// r8 must contain 0x09FFFFFE address
// r9 must contain 0xA55A constant
// r10-r11 are scratch registers!


// r0: output byte buffer (output)
// r1: number of blocks to read
.global sc_read_sectors_w0
.type sc_read_sectors_w0,function
sc_read_sectors_w0:
  push {r4-r12, lr}
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  sub sp, $48      // Some space for the code

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_READ_REGISTER_16

  1:
    // This is the slower unaligned version (a bit more friendly for this use case)
    // Perform a wait on the data bus, until the bits are pulled zero once.
    mov r4, $(CMD_WAIT_DATA)
    2:
      subs r4, r4, $1
      moveq r0, $1      // Non zero retvalue on timeout error
      beq 3f            // Function return.
      bl sd_ldrh
      tst r2, $(SD_DATA0)
    bne 2b

    // Go ahead and read a 512 byte sector
    mov r4, $(512 / 4)     // Performs four bytes per iteration

    2:
      bl sd_ldm4            // Reads four bytes in one go.
      lsr  r2,  r2, #24     // Placed in the top 8 bits of the register
      lsr  r3,  r3, #24
      lsr  r6,  r6, #24
      lsr r12, r12, #24
      strb r2, [r0], #1     // Stores the received byte
      strb r3, [r0], #1
      strb r6, [r0], #1
      strb r12, [r0], #1
      subs r4, r4, $1
      bne 2b

    // Skip 8 bytes
    bl sd_ldm4
    bl sd_ldm4

    bl sd_ldrh            // Final clock: should go all high (0xF)

    subs r1, r1, $1
  bne 1b

  mov r0, $0            // Return value: success
3:
  add sp, $48
  pop {r4-r12, lr}
  bx lr



// Writes a bunch of 512 byte sectors, calculating checksums for them as well
// as checking any error codes returned (and waiting between blocks).

// r0: data byte buffer (input)
// r1: number of 512byte blocks to send/write
// returns non zero on timeout or data rejected (ie. CRC error, write error...)
.global sc_write_sectors_w0
.type sc_write_sectors_w0,function
sc_write_sectors_w0:
  push {r4-r12, lr}
  mov r5, $(SC_WRITE_REGISTER_8)
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  sub sp, $(8 + 48)    // Some space for the CRC buffer, and the RAM routine.
  mov r4, r0           // Input buffer
  mov r6, r1           // Block count

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  // Calculate crc for the first block.
  add r1, sp, $48
  bl crc16_nibble_512_nolut8bit

  1: // Loop r6 times. Try to perform checksum while waiting for write to finish.

    // Go ahead send the data! Send the first byte token (0xFE? should be 0xFC!)
    mov r2, $0xFFFFFFFF
    bl sd_str
    bl sd_str
    bl sd_str
    bl sd_strh
    mov r2, $0
    bl sd_strh

    mov r1, $(512)           // Pushing 512 bytes in bytes
    2:
      ldrb r2, [r4], #1      // Load byte from buffer
      bl sd_str
      subs r1, r1, $1
      bne 2b

    .set i, 0
    .rept 8                  // Send 16x4 bits of checksum
      ldrb r2, [sp, #(i + 48)]
      bl sd_str
      .set i, i+1
    .endr

    // Response token is 8 bits, only transmitted via DAT0.
    // Write one to the bus, read a couple more times (ignore 3 MSB)
    mov  r2, $(~0)            // All data lines high after last bit
    bl sd_strh
    bl sd_strh
    bl sd_strh
    bl sd_strh

    // Get status code (3 bits) + dummy bit
    mov r0, $0
    .rept 4
      lsl r0, $1
      bl sd_ldrh
      tst r2, $SD_DATA0
      orrne r0, $0x1
    .endr

    // Pipe one byte, some cards do not start actually writing (ie. go busy?)
    // until we pipe an extra clock? Perhaps not, but does no harm.
    .rept 4
      bl sd_ldr
    .endr

    // Check status code, bail on error
    cmp r0, $0x5              // 0.010.1 means "data accepted" (0.status.1)
    bne 3f                    // Wait and exit with error

    // Break out if we are on the last block!
    subs r6, $1
    beq 5f

    // Calculate the block checksum for the next block to send.
    // (helps hiding busy latency!)
    mov r0, r4
    add r1, sp, $48
    bl crc16_nibble_512_nolut8bit

    // Perform a wait on the data bus, DAT0 goes high when ready.
    mov r1, $(CMD_WAIT_DATA)
    2:
      subs r1, r1, $1
      beq 4f
      bl sd_ldrh
      tst r2, $(SD_DATA0)
    beq 2b

    b 1b  // Continue loop on the next block.

5:
  // Perform a final wait, ensure we leave with no pending operations.
  mov r0, $(CMD_WAIT_DATA)
  2:
    subs r0, r0, $1
    beq 4f
    bl sd_ldrh
    tst r2, $(SD_DATA0)
  beq 2b

  add sp, $(8 + 48)
  pop {r4-r12, lr}
  mov r0, $0            // Return OK
  bx lr

3:  // Wait-and-exit on error
  mov r0, $(CMD_WAIT_DATA)
  2:
    subs r0, r0, $1
    beq 4f
    bl sd_ldrh
    tst r2, $(SD_DATA0)
  beq 2b

4:  // Return non zero on timeout/response error
  add sp, $(8 + 48)
  pop {r4-r12, lr}
  mov r0, $1
  bx lr


// Command-related routines


.global send_empty_clocks
// Sends empty clocks (just read the CMD register to force a clock)
// r0: number of clocks to send
send_empty_clocks:
  push {r5-r12, lr}
  sub sp, $48      // Some space for the code
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_RDWR_COMMAND
  1:
    bl sd_ldm4
    subs r0, $8
    bgt 1b
  add sp, $48
  pop {r5-r12, lr}
  bx lr


.global wait_sdcard_idle
// Waits until the CMD line (bit0) goes high, indicating IDLE.
// r0: number of iterations before giving up
wait_sdcard_idle:
  push {r5-r12, lr}
  sub sp, $48      // Some space for the code
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_RDWR_COMMAND
  mov r3, r0
  mov r0, $1
  1:
    bl sd_ldrh
    lsls r2, #31       // Extract LSB to Carry Flag
    bne 2f             // If LSB is set, return true (Idle reached)
    subs r3, $1        // Decrement timeout.
    bne 1b

  mov r0, $0
2:
  add sp, $48
  pop {r5-r12, lr}
  bx lr


.global wait_dat0_idle
// Waits until the DAT0 line goes high, indicating not busy.
// r0: number of iterations before giving up
wait_dat0_idle:
  push {r5-r12, lr}
  sub sp, $48
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_WRITE_REGISTER_8

  ldr r3, =SD_DATA0
  1:
    bl sd_ldrh
    tst r2, $(SD_DATA0)      // Check the right bit (SD_DATA0)
    bne 2f                   // If bit set, it is idlea again, return true
    subs r0, $1              // Decrement timeout.
    bne 1b

  add sp, $48
  pop {r5-r12, lr}
  mov r0, $0
  bx lr
2:
  add sp, $48
  pop {r5-r12, lr}
  mov r0, $1
  bx lr


.global receive_sdcard_response
// Waits for a response (or returns error) and receives a response to a buffer.
// r0: buffer pointer where we write the response (can be null!)
// r1: response length in bytes
// r2: number of iterations before giving up
receive_sdcard_response:
  push {r4-r12, lr}
  sub sp, $48
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r3, ((safe_sd_operation) + i*4)
    str r3, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_RDWR_COMMAND

  mov r3, r2
  mov r6, $7           // First bit belongs to first byte (always zero)
  mov r4, $0

  1:
    bl sd_ldrh
    lsrs r2, #1        // Extract LSB to Carry Flag
    bcc 4f             // If LSB is clear, we can receive the next bits!
    subs r3, $1        // Decrement timeout.
    bne 1b

  mov r0, $0           // Timeout, return false
  add sp, $48
  pop {r4-r12, lr}
  bx lr

  3:

    // Read 8 bits (MSB to LSB)
    mov r6, $8
    4:
      bl sd_ldrh
      lsrs r2, #1      // Extract LSB into Carry Flag
      adc r4, r4       // Shift register left by 1, add CF to LSB
      subs r6, $1
      bne 4b

    cmp r0, $0
    strneb r4, [r0]      // Store it in the buffer, if ptr!=null
    addne r0, $1

    subs r1, $1
    bne 3b

  mov r0, $1           // Return true
  add sp, $48
  pop {r4-r12, lr}
  bx lr



.global send_sdcard_commandbuf
// Waits for a response (or returns error) and receives a response to a buffer.
// r0: buffer pointer to send
// r1: command length in bytes
send_sdcard_commandbuf:
  push {r5-r12, lr}
  sub sp, $48
  ldr r7, =(0x04000000 + REG_IME)
  ldr r8, =0x09FFFFFE
  ldr r9, =0xA55A

  // Copy the template routine to the stack
  .set i, 0
  .rept SAFE_OP_ROUTINE_SIZE
    ldr r2, ((safe_sd_operation) + i*4)
    str r2, [sp, #(i*4)]
    .set i, i+1
  .endr

  ldr r5, =SC_RDWR_COMMAND

  1:
    ldrb r2, [r0], #1
    orr r2, r2, r2, lsl #17
    lsl r3, r2, #2
    lsl r6, r2, #4
    lsl r12, r2, #6
    bl sd_stm4

    subs r1, $1
    bne 1b

  add sp, $48
  pop {r5-r12, lr}
  bx lr



// Supercard SD interface "safe" read/write operation
#define SD_OPERATION(fn_name, ...)                                            \
  fn_name:                                                                    \
    push {lr};   /* Adding 4 bytes to the stack, careful! */                  \
                                                                              \
    /* Insert operation instruction */                                        \
    ldr r11, 1f;                                                              \
    str r11, [sp, #(4 + SAFE_OP_INST_OFF*4)];                                 \
                                                                              \
    /* Disable IRQs */                                                        \
    mov r11, $0;                                                              \
    swp r10, r11, [r7]; /* Writes zero to REG_IME, preserve previous value */ \
                                                                              \
    /* Actually call the routine */                                           \
    mov lr, pc;                                                               \
    add pc, sp, $4;                                                           \
                                                                              \
    /* (maybe) re-enable IRQs */                                              \
    str r10, [r7];                                                            \
                                                                              \
    pop {pc};                                                                 \
  1:                                                                          \
    __VA_ARGS__;                                                              \


SD_OPERATION(sd_ldr,  ldr  r2, [r5]);
SD_OPERATION(sd_ldrh, ldrh r2, [r5]);
SD_OPERATION(sd_str,  str  r2, [r5]);
SD_OPERATION(sd_strh, strh r2, [r5]);

SD_OPERATION(sd_ldm4, ldmia r5, {r2, r3, r6, r12});
SD_OPERATION(sd_stm4, stmia r5, {r2, r3, r6, r12});


// Actual implementation template. (12 insts, 48 bytes)
safe_sd_operation:
  // Map SD card driver into the high address space (5 insts)
  mov r11, $0x7       // SDRAM + RW + SD iface
  strh r9,  [r8]
  strh r9,  [r8]
  strh r11, [r8]
  strh r11, [r8]

  nop   // Actual operation to perform! To be patched on demand!

  mov r11, $0x1       // SDRAM + RO
  strh r9,  [r8]
  strh r9,  [r8]
  strh r11, [r8]
  strh r11, [r8]

  bx lr

// Constant pool goes here.
.pool


