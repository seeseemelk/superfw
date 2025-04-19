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

// Binary assets (uncompressed) used in GBA mode
// These are kept here and compressed along with the firmware due to their
// small size and better compression ratio when kept toghether (due to dupe code).

.text
.balign 4

// In-game menu assets
.global ingame_menu_payload
ingame_menu_payload:
  .incbin "ingamemenu.payload"
ingame_menu_payload_end:

.global ingame_menu_payload_size
ingame_menu_payload_size:
  .word (ingame_menu_payload_end - ingame_menu_payload)

// Direct save payload
.global directsave_payload
directsave_payload:
  .incbin "directsave.payload"
directsave_payload_end:

.global directsave_payload_size
directsave_payload_size:
  .word (directsave_payload_end - directsave_payload)

// DLDI payload (builtin!)
.global dldi_payload
dldi_payload:
  .incbin "superfw.dldi.payload"


