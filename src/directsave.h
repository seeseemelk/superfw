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

// Direct save payload patching structure
// This  This is used to load and patch the menu with the required values.
// This header is used both by gcc and as!

typedef struct {
  uint32_t entrypoint;                 // ARM entrypoint for the requested function
  uint32_t base_sector;                // Sector number where the contiguous save file lives.
  uint32_t memory_size;                // Save file size in bytes
  uint32_t sd_mutex;                   // Mutex value (set to one when DS is using the SD card)
  uint32_t drv_issdhc;                 // Boolean (is SDHC card)
  uint32_t drv_rca;                    // SD card RCA id
} t_dirsave_header;

// Built-in assets
extern const uint8_t directsave_payload[];
extern const uint32_t directsave_payload_size;

#define SD_MUTEX_OFFSET    (3*4)

