/*
 * Copyright (C) 2025 David Guillen Fandos <david@davidgf.net>
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

// Support for various GBA emulators that require some minimal header/rom list.

#include <string.h>

#include "emu.h"
#include "util.h"

typedef struct {
  char title[32];
  uint32_t romsize;
  uint32_t flags1;
  uint32_t flags2;
  uint32_t padding;
} t_pocketnes_header;

unsigned pocket_nes_header(uint8_t *buffer, const char *fn, unsigned fs) {
  // Copy the base filename into the name buffer
  t_pocketnes_header hdr;
  const char *bname = file_basename(fn);

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.title, bname, sizeof(hdr.title) - 1);
  hdr.romsize = fs;
  memcpy32(buffer, &hdr, sizeof(hdr));

  return sizeof(hdr);
}

typedef struct {
  uint32_t ident;
  uint32_t romsize;
  uint32_t flags1;
  uint32_t flags2;
  uint32_t padding[4];
  char title[32];
} t_smsadv_header;

unsigned smsadvance_header(uint8_t *buffer, const char *fn, unsigned fs) {
  // Copy the base filename into the name buffer
  t_smsadv_header hdr;
  const char *bname = file_basename(fn);

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.title, bname, sizeof(hdr.title) - 1);
  hdr.romsize = fs;
  hdr.ident = 0x1A534D53;   // SMS + 0x1A (little endian)
  memcpy32(buffer, &hdr, sizeof(hdr));

  return sizeof(hdr);
}

typedef struct {
  uint32_t ident;
  uint32_t romsize;
  uint32_t flags;
  uint32_t undef;
  uint32_t isbios;
  uint32_t padding[3];
  char title[32];
} t_wasabigba_header;

unsigned wasabigba_header(uint8_t *buffer, const char *fn, unsigned fs) {
  // Copy the base filename into the name buffer
  t_wasabigba_header hdr;
  const char *bname = file_basename(fn);

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.title, bname, sizeof(hdr.title) - 1);
  hdr.romsize = fs;
  hdr.ident = 0x1A565357;   // WSV + 0x1A (little endian)
  memcpy32(buffer, &hdr, sizeof(hdr));

  return sizeof(hdr);
}

typedef struct {
  uint32_t ident;
  uint32_t romsize;
  uint32_t flags;
  uint32_t undef;
  uint8_t isbios;
  uint8_t padding[15];
  char title[32];
} t_ngpgba_header;

unsigned ngpgba_header(uint8_t *buffer, const char *fn, unsigned fs) {
  // Copy the base filename into the name buffer
  t_ngpgba_header hdr;
  const char *bname = file_basename(fn);

  memset(&hdr, 0, sizeof(hdr));
  memcpy(hdr.title, bname, sizeof(hdr.title) - 1);
  hdr.romsize = fs;
  hdr.ident = 0x1A50474E;   // PGN + 0x1A (little endian)
  memcpy32(buffer, &hdr, sizeof(hdr));

  return sizeof(hdr);
}

// Emulator loader table. Add entries here!

const t_emu_loader emu_loaders[] = {
  {"gb",  "gbc-emu",    NULL},
  {"gbc", "gbc-emu",    NULL},
  {"nes", "pocketnes",  pocket_nes_header},
  {"sms", "smsadvance", smsadvance_header},
  {"gg",  "smsadvance", smsadvance_header},
  {"sg",  "smsadvance", smsadvance_header},
  {"sv",  "wasabigba",  wasabigba_header},
  {"ngc", "ngpgba",     ngpgba_header},
  {NULL, NULL, NULL},        // End marker!
};

