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

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "gbahw.h"
#include "fatfs/ff.h"
#include "common.h"
#include "patchengine.h"

#define GBA_ROM_ADDR_START   0x08000000
#define GBA_ROM_ADDR_END     0x09FFFFFF

typedef struct {
  uint32_t signature;    // "PTDB" in ASCII
  uint32_t dbversion;    // Format version
  uint32_t patchcnt;     // Patch count
  uint32_t idxcnt;       // Number of IDX blocks
  char date[8];          // Creating date (ASCII encoded)
  char version[8];       // DB version (ASCII encoded)
  char creator[32];      // DB author/creator (ASCII encoded)
} t_db_header;

typedef struct {
  uint8_t gcode[4];
  uint32_t offset;       // LSB is game version (8 bits), MSB is byte offset
} t_db_idx;

// Game code is 4 bytes long (ascii chars in theory) + 1 byte for versioning
static int gcodecmp(const uint8_t *g1, const uint8_t *g2) {
  for (unsigned i = 0; i < 5; i++) {
    if (g1[i] < g2[i])
      return -1;
    if (g1[i] > g2[i])
      return 1;
  }
  return 0;
}

void patchmem_dbinfo(const uint8_t *dbptr, uint32_t *pcnt, char *version, char *date, char *creator) {
  const t_db_header *dbh = (t_db_header*)dbptr;
  *pcnt = dbh->patchcnt;
  memcpy(date, dbh->date, sizeof(dbh->date));
  memcpy(version, dbh->version, sizeof(dbh->version));
  memcpy(creator, dbh->creator, sizeof(dbh->creator));
}

// Routines to lookup patches from the patch database in memory
bool patchmem_lookup(const uint8_t *gamecode, const uint8_t *dbptr, t_patch *pdata) {
  const t_db_header *dbh = (t_db_header*)dbptr;
  if (dbh->signature != 0x31424450 ||      // PTDB signature mismatch
      dbh->dbversion != 0x00010000)        // Version check
    return false;

  // Skip header and program block.
  const t_db_idx *dbidx = (t_db_idx*)&dbptr[1024];
  // Skip the index block to address data entries.
  const uint32_t *entries = (uint32_t*)&dbptr[1024 + 512 * dbh->idxcnt];

  // Load programs as well
  int pgn = 0;
  const uint8_t *pgrpage = &dbptr[512];
  for (int i = 0; i < MAX_PATCH_PRG; i++)
    pdata->prgs[i].length = 0;
  for (int i = 0; i < 512 && pgn < MAX_PATCH_PRG; i++) {
    unsigned cnt = pgrpage[i];
    if (!cnt)
      break;

    if (cnt > sizeof(pdata->prgs[pgn].data))
      return false;

    pdata->prgs[pgn].length = cnt;
    memcpy(pdata->prgs[pgn++].data, &pgrpage[i+1], cnt);
    i += cnt;
  }

  for (unsigned i = 0; i < dbh->patchcnt; i++) {
    if (!gcodecmp(dbidx[i].gcode, gamecode)) {
      uint32_t offset = dbidx[i].offset >> 8;
      const uint32_t *p = &entries[offset];
      const uint32_t pheader = *p++;

      pdata->wcnt_ops = (pheader >>  0) & 0xFF;
      pdata->save_ops = (pheader >>  8) & 0x1F;    // Only 5 bits
      pdata->irqh_ops = (pheader >> 16) & 0xFF;
      pdata->rtc_ops =  (pheader >> 24) & 0x0F;    // Only 4 bits

      pdata->save_mode = (pheader >> 13) & 0x7;    // 3 bits

      const unsigned numops = pdata->wcnt_ops + pdata->save_ops + pdata->irqh_ops + pdata->rtc_ops;

      if ((pheader >> 28) & 0x1) {
        // Hole/Trailing space information, placed in the last op
        pdata->hole_addr = (p[numops] >> 16) << 10;   // In KiB chunks
        pdata->hole_size = (p[numops] & 0xFFFF) << 10;
      }

      // Copy patch words
      memcpy(&pdata->op[0], p, numops * sizeof(uint32_t));

      return true;
    }
  }

  return false;
}

// Write a byte to a buffer ensuring that only 32 bit accesses are performed.
static void write_mem8(uintptr_t ptraddr, uint8_t bytedata) {
  volatile uint32_t *aptr = (uint32_t*)(ptraddr & ~3U);
  unsigned sha = ((ptraddr & 3) * 8);
  uint32_t data = *aptr & (~(0xFF << sha));
  data |= (bytedata << sha);
  *aptr = data;
}

static void write_mem32(uintptr_t ptraddr, uint32_t worddata) {
  write_mem8(ptraddr + 0, worddata >>  0);
  write_mem8(ptraddr + 1, worddata >>  8);
  write_mem8(ptraddr + 2, worddata >> 16);
  write_mem8(ptraddr + 3, worddata >> 24);
}

static void copy_mem16(uintptr_t ptraddr, const uint16_t *fnptr, unsigned size) {
  for (unsigned i = 0; i < size; i++)
    ((volatile uint16_t*)ptraddr)[i] = fnptr[i];
}

// Flashing/Eeprom routines flavours:
typedef struct {
  void *ptr;
  const uint32_t *size;
} f_func_info;

typedef struct {
  f_func_info eeprom_read;
  f_func_info eeprom_write;
  f_func_info flash_read;
  f_func_info flash_write_sector;
  f_func_info flash_write_byte;
  f_func_info flash_erase_sector;
  f_func_info flash_erase_device;
} t_psave_funcs;

typedef struct {
  uint32_t dspayload_addr;
  const t_psave_funcs *sfns;
} t_psave_info;

#define SFUNC(start, end) { (start), (end) - (start) },

static const t_psave_funcs psram_conversion_64k = {
  { patch_eeprom_read_sram64k,        &patch_eeprom_read_sram64k_size },
  { patch_eeprom_write_sram64k,       &patch_eeprom_write_sram64k_size },
  { patch_flash_read_sram64k,         &patch_flash_read_sram64k_size },
  { patch_flash_write_sector_sram64k, &patch_flash_write_sector_sram64k_size },
  { patch_flash_write_byte_sram64k,   &patch_flash_write_byte_sram64k_size },
  { patch_flash_erase_sector_sram64k, &patch_flash_erase_sector_sram64k_size },
  { patch_flash_erase_device_sram64k, &patch_flash_erase_device_sram64k_size },
};

static const t_psave_funcs psram_conversion_128k = {
  { patch_eeprom_read_sram64k,        &patch_eeprom_read_sram64k_size },
  { patch_eeprom_write_sram64k,       &patch_eeprom_write_sram64k_size },
  { patch_flash_read_sram128k,         &patch_flash_read_sram128k_size },
  { patch_flash_write_sector_sram128k, &patch_flash_write_sector_sram128k_size },
  { patch_flash_write_byte_sram128k,   &patch_flash_write_byte_sram128k_size },
  { patch_flash_erase_sector_sram128k, &patch_flash_erase_sector_sram128k_size },
  { patch_flash_erase_device_sram128k, &patch_flash_erase_device_sram128k_size },
};

static const t_psave_funcs pdirectsave = {
  { patch_eeprom_read_directsave,        &patch_eeprom_read_directsave_size },
  { patch_eeprom_write_directsave,       &patch_eeprom_write_directsave_size },
  { patch_flash_read_directsave,         &patch_flash_read_directsave_size },
  { patch_flash_write_sector_directsave, &patch_flash_write_sector_directsave_size },
  { patch_flash_write_byte_directsave,   &patch_flash_write_byte_directsave_size },
  { patch_flash_erase_sector_directsave, &patch_flash_erase_sector_directsave_size },
  { patch_flash_erase_device_directsave, &patch_flash_erase_device_directsave_size },
};

// Flash patching functions per-mode.

#define FN_THUMB_RET0     0x47702000
#define FN_THUMB_RET1     0x47702001
#define FN_ARM_RET0       0xe3a00000
#define FN_ARM_RET1       0xe3a00001
#define FN_ARM_RETBX      0xe12fff1e

void apply_patch_ops(const uint32_t *ops, unsigned pcount, const t_patch_prog *prgs, const t_psave_info *psi) {
  for (unsigned i = 0; i < pcount; i++) {
    uint32_t opc = ops[i] >> 28;
    uint32_t arg = (ops[i] >> 25) & 7;
    uint32_t addr = ops[i] & 0x1FFFFFF;

    switch (opc) {
    case 0x0:
      // Patch a full program into an address.
      for (unsigned j = 0; j < prgs[arg].length; j++)
        write_mem8(GBA_ROM_ADDR_START + addr + j, prgs[arg].data[j]);
      break;
    case 0x1:   // Patch Thumb instruction
      *(volatile uint16_t *)(GBA_ROM_ADDR_START + addr) = 0x46C0; // mov r8, r8
      break;
    case 0x2:   // Patch ARM instruction
      *(volatile uint32_t *)(GBA_ROM_ADDR_START + addr) = 0xE1A00000; // mov r0, r0
      break;
    case 0x3:   // Write N bytes to address
      for (unsigned j = 0; j < arg + 1; j++)
        write_mem8(GBA_ROM_ADDR_START + addr + j, ops[(j / 4) + 1] >> (j * 8));
      i += (arg + 1 + 3) / 4;
      break;
    case 0x4:   // Write N words to address
      for (unsigned j = 0; j < arg + 1; j++)
        write_mem32(GBA_ROM_ADDR_START + addr + j * 4, ops[++i]);
      break;
    case 0x5:   // Patch function with a dummy one
      switch (arg) {
        case 0:
          write_mem32(GBA_ROM_ADDR_START + addr, FN_THUMB_RET0); break;
        case 1:
          write_mem32(GBA_ROM_ADDR_START + addr, FN_THUMB_RET1); break;
        case 4:
          write_mem32(GBA_ROM_ADDR_START + addr, FN_ARM_RET0);
          write_mem32(GBA_ROM_ADDR_START + addr + 4, FN_ARM_RETBX);
          break;
        case 5:
          write_mem32(GBA_ROM_ADDR_START + addr, FN_ARM_RET1);
          write_mem32(GBA_ROM_ADDR_START + addr + 4, FN_ARM_RETBX);
          break;
      };
      break;

    case 0x7:    // RTC handlers
      switch (arg) {
      case 0:
        copy_mem16(GBA_ROM_ADDR_START + addr, patch_rtc_probe, patch_rtc_probe_end - patch_rtc_probe);
        break;
      case 1:
        copy_mem16(GBA_ROM_ADDR_START + addr, patch_rtc_reset, patch_rtc_reset_end - patch_rtc_reset);
        break;
      case 2:
        copy_mem16(GBA_ROM_ADDR_START + addr, patch_rtc_getstatus, patch_rtc_getstatus_end - patch_rtc_getstatus);
        break;
      case 3:
        copy_mem16(GBA_ROM_ADDR_START + addr, patch_rtc_gettimedate, patch_rtc_gettimedate_end - patch_rtc_gettimedate);
        break;
      };
      break;

    case 0x8:    // EEPROM memory handlers
      switch (arg) {
      case 0:      // EEPROM rease handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->eeprom_read.ptr, *psi->sfns->eeprom_read.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->eeprom_read.size, psi->dspayload_addr);
        break;
      case 1:      // EEPROM write handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->eeprom_write.ptr, *psi->sfns->eeprom_write.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->eeprom_write.size, psi->dspayload_addr);
        break;
      };
      break;

    case 0x9:    // FLASH memory handlers
      switch (arg) {
      case 0x0:    // FLASH read handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->flash_read.ptr, *psi->sfns->flash_read.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->flash_read.size, psi->dspayload_addr);
        break;
      case 0x1:    // FLASH erase device handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->flash_erase_device.ptr, *psi->sfns->flash_erase_device.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->flash_erase_device.size, psi->dspayload_addr);
        break;
      case 0x2:    // FLASH erase sector handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->flash_erase_sector.ptr, *psi->sfns->flash_erase_sector.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->flash_erase_sector.size, psi->dspayload_addr);
        break;
      case 0x3:    // FLASH write sector handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->flash_write_sector.ptr, *psi->sfns->flash_write_sector.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->flash_write_sector.size, psi->dspayload_addr);
        break;
      case 0x4:    // FLASH write device handler
        copy_mem16(GBA_ROM_ADDR_START + addr, psi->sfns->flash_write_byte.ptr, *psi->sfns->flash_write_byte.size);
        write_mem32(GBA_ROM_ADDR_START + addr + *psi->sfns->flash_write_byte.size, psi->dspayload_addr);
        break;
      };
    };
  }
}


// Applies a patch directly into the ROM memory
bool patch_apply_rom(const t_patch *pdata, const t_rtc_state *rtc_clock, uint32_t igmenu_addr, uint32_t ds_addr) {
  // Apply the WAIT CNT patches
  unsigned base_cnt = pdata->wcnt_ops + pdata->save_ops;
  const uint32_t *ops = &pdata->op[0];
  // Save patch routines vary depending on whether DirectSave is enabled or not.
  t_psave_info psi = {
    .dspayload_addr = ds_addr,
    .sfns = ds_addr                                ? &pdirectsave :
            pdata->save_mode == SaveTypeFlash1024K ? &psram_conversion_128k
                                                   : &psram_conversion_64k
  };

  // Apply the waitcnt and save patches.
  apply_patch_ops(ops, base_cnt, pdata->prgs, &psi);

  // Apply optional patches, they are placed right after.
  if (igmenu_addr) {
    apply_patch_ops(&ops[base_cnt], pdata->irqh_ops, pdata->prgs, &psi);

    // Calculate the branch from 0x08000000 to igmenu_addr
    unsigned brop = 0xEA000000 | ((igmenu_addr - 0x08000000 - 8) >> 2);
    // Patch the first instruction with the branch opcode
    write_mem32(GBA_ROM_ADDR_START, brop);
  }

  if (rtc_clock) {
    // Apply RTC patches and setup initial RTC clock
    apply_patch_ops(&ops[base_cnt + pdata->irqh_ops], pdata->rtc_ops, pdata->prgs, &psi);

    write_mem8(GBA_ROM_ADDR_START + 0xC5, rtc_clock->hour);
    write_mem8(GBA_ROM_ADDR_START + 0xC6, rtc_clock->mins);
    write_mem8(GBA_ROM_ADDR_START + 0xC7, rtc_clock->day);
    write_mem8(GBA_ROM_ADDR_START + 0xC8, rtc_clock->month);
    write_mem8(GBA_ROM_ADDR_START + 0xC9, rtc_clock->year);
  }

  return true;
}

