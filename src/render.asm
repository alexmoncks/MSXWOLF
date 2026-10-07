; ============================================================================
; render.asm - the frame: what the Z80 sends to geo3d and to the V9968
;
; World: 256 units a cell, walls 256 high, the eye at 128; x grows east, z
; south; the map is 64 x 64 cells. Camera: yaw only, so the matrix is
; [rx 0 rz; 0 1 0; fx 0 fz] with the forward vector f = (sin yaw, -cos yaw)
; and the right one r = (cos yaw, sin yaw), and T = -(M * eye position).
; geo3d: F 128 (90 degrees), 256 x 180, ZNEAR 2, light (0, 1, 0), TIMP,
; textures at row 512, TSTRIDE 64.
;
; A face is four vertices seen clockwise (top left, top right, bottom
; right, bottom left), a normal (0, ny, 0) and four texture points. With the
; light straight up, ny picks geo3d's "light level" 0..6 whatever the yaw,
; and here the level is nothing but the 64-row band of the texture area:
; bands 0-2 hold the 12 wall textures, bands 3-5 their dark copies (walls
; facing east or west, as in Wolfenstein 3D), band 6 and its v offsets the
; sprites. ny_tab[n] gives band n.
;
; Vertices go in pairs: top at index n, bottom at n + 1.
;
; What stays in geo3d's RAM, in this order:
;   near strips   the walls of the 3 x 3 cells around the player, four strips
;                 each (st_build, when the player enters a cell)
;   far faces     the rest of the cell's list, filtered by bearing and by the
;                 doors that hide them (st_far: also after a turn of more
;                 than YAW_MARGIN, or when a door starts to open or shuts)
;   objects       lamps, tables, treasure: billboards turned to the yaw of
;                 the moment they were built (ob_build: also after a turn of
;                 more than SPR_MARGIN, or when the player takes one)
; and what goes in every frame, after them:
;   one face for each near wall that crosses Z = 16 (near_emit), the doors
;   in sight that are not fully open (dr_emit), the monsters (bb_emit).
; tools/sim.py build_frame() is this file in Python.
; ============================================================================

geo_init:
        ld a, 0x18
        out (GEO_IDX), a
        ld hl, geo_cam
        ld bc, 12 * 256 + GEO_DAT
        otir                        ; F, CX, CY, ZNEAR, W, H
        ld a, 0x40
        out (GEO_IDX), a
        ld hl, geo_r40
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; VADDR, EADDR, NVERT, NEDGE, COLOR, LOP, YPAGE
        ld a, 0x58
        out (GEO_IDX), a
        ld hl, geo_r58
        ld bc, 8 * 256 + GEO_DAT
        otir                        ; FADDR, NFACE, LX, LY, LZ
        ld a, 0x60
        out (GEO_IDX), a
        ld hl, geo_r60
        ld bc, 6 * 256 + GEO_DAT
        otir                        ; TEXX, TEXY, TSTRIDE, TADDR
        ld hl, 16384
        ld (cambuf + 8), hl         ; M11 = 1 (the other constant words are 0)
        ld a, 1
        ld (st_geo), a
        ret

geo_cam:
        dw G3_F, G3_CX, G3_CY, G3_ZNEAR, G3_W, G3_H
geo_r40:
        db 0, 0, 0, 0, 15, TIMP, 0, 0
geo_r58:
        db 0, 0
        dw 0, 16384, 0
geo_r60:
        dw 0, TEXY
        db TSTRIDE, 0

; wait for RUN busy = 0 (a stuck geo3d is given up after about 1 s)
geo_wait:
        ld bc, 0
gw_1:   in a, (GEO_IDX)
        rrca
        ret nc
        dec bc
        ld a, b
        or c
        jr nz, gw_1
        xor a
        ld (st_geo), a
        ret

; ---------------------------------------------------------------- the camera
cam_setup:
        ld a, (p_x + 1)
        ld (p_cx), a
        ld a, (p_z + 1)
        ld (p_cz), a
        ld a, (p_yaw)
        call sin_a
        ld (cam_fx), hl
        ld (cam_rz), hl
        ld (cambuf + 4), hl         ; M02 = rz
        ld (cambuf + 12), hl        ; M20 = fx
        ld a, (p_yaw)
        add a, 64
        call sin_a                  ; cos yaw
        ld (cam_rx), hl
        ld (cambuf), hl             ; M00 = rx
        call neg_hl
        ld (cam_fz), hl
        ld (cambuf + 16), hl        ; M22 = fz
        ; TX = -(rx px + rz pz)
        ld de, (cam_rx)
        ld bc, (p_x)
        call mulq14
        push hl
        ld de, (cam_rz)
        ld bc, (p_z)
        call mulq14
        pop de
        add hl, de
        call neg_hl
        ld (cambuf + 18), hl
        ; TY = -eye
        ld hl, (p_eye)
        call neg_hl
        ld (cambuf + 20), hl
        ; TZ = -(fx px + fz pz)
        ld de, (cam_fx)
        ld bc, (p_x)
        call mulq14
        push hl
        ld de, (cam_fz)
        ld bc, (p_z)
        call mulq14
        pop de
        add hl, de
        call neg_hl
        ld (cambuf + 22), hl
        ret

; ---------------------------------------------------------------- the map
; The grid (bank 1, 8000h, 64 bytes a row): bits 7-6 the kind (00 floor,
; 01 floor with an object in the way, 10 door, 11 wall), bits 5-0 the area
; of a floor cell (63: the elevator), the door's number, the wall's texture.

; B = cx, C = cz -> HL -> the cell's byte, A = it (keeps BC, DE)
grid_at:
        ld a, c
        rrca
        rrca
        ld h, a
        and 0xC0
        or b
        ld l, a
        ld a, h
        and 0x0F
        or 0x80                     ; (map_grid is at 8000h)
        ld h, a
        ld a, (hl)
        ret

; B = cx, C = cz -> NZ if nobody can stand there: a wall, an object, a door
; that is not open (keeps BC)
solid_at:
        call grid_at
        and 0xC0
        ret z
        cp 0x80
        jr nz, sa_1
        ld a, (hl)
        and 63
        ld e, a
        ld d, 0
        ld hl, door_st
        add hl, de
        ld a, (hl)
        cp DS_OPEN
        ret
sa_1:   or 1
        ret

; B = cx, C = cz -> NZ if a bullet or a look stops there: a wall, or a door
; less than half open (keeps BC)
shot_at:
        call grid_at
        and 0xC0
        ret z
        cp 0x40
        jr z, sh_0                  ; an object: no
        cp 0x80
        jr nz, sa_1                 ; a wall
        ld a, (hl)
        and 63
        ld e, a
        ld d, 0
        ld hl, door_pos
        add hl, de
        ld a, (hl)
        cp 128
        ccf
        sbc a, a
        cpl                         ; pos < 128: FFh
        or a
        ret
sh_0:   xor a
        ret

; ---------------------------------------------------------------- static parts
; what is in geo3d's RAM, against what the player needs now
st_check:
        ld a, (p_cx)
        ld hl, st_cx
        cp (hl)
        jr nz, st_build
        ld a, (p_cz)
        inc hl
        cp (hl)
        jr nz, st_build
        ld a, (st_dirty)
        or a
        jp nz, st_far
        ld a, (p_yaw)
        ld hl, st_yaw
        sub (hl)
        jp p, sc_1
        neg
sc_1:   cp YAW_MARGIN + 1
        jp nc, st_far
        ld a, (ob_dirty)
        or a
        jp nz, ob_build
        ld a, (p_yaw)
        ld hl, ob_yaw
        sub (hl)
        jp p, sc_2
        neg
sc_2:   cp SPR_MARGIN + 1
        ret c
        jp ob_build

; The cell's list (bank PVS_BANK0 up; pvsptr in bank 2 has bank and address
; for each map cell), see tools/gen_wolf.py:
;   db n ; n x 2   near walls: i | j << 2 | dir << 4 ; texture | dark << 4
;   5 bytes        areas in sight
;   db n ; n x 4   objects: number, a0, lim, dep
;   db n ; n x 4   doors: number, a0, lim, dep
;   db n ; n x 6   far faces: corner A x, z ; dir | texture << 2 | dark << 6 |
;                  split << 7 ; a0, lim ; dep
; a0, lim: in view when ((yaw - a0) & 255) <= lim. dep: 0, or the number
; + 1 of the door that hides it while shut. All but the far faces go to RAM.
st_build:
        ld hl, (st_builds)
        inc hl
        ld (st_builds), hl
        ld a, (p_cx)
        ld (st_cx), a
        ld b, a
        ld a, (p_cz)
        ld (st_cz), a
        ; pvsptr + 3 * (64 cz + cx)
        rrca
        rrca
        ld h, a
        and 0xC0
        or b
        ld l, a
        ld a, h
        and 0x0F
        ld h, a
        ld e, l
        ld d, h
        add hl, hl
        add hl, de
        ld de, pvsptr
        add hl, de
        ld a, 2
        ld (BANK2_SEL), a
        ld a, (hl)
        inc hl
        ld (st_bank), a
        ld e, (hl)
        inc hl
        ld d, (hl)
        ex de, hl                   ; HL -> the list, A = its bank
        ld (BANK2_SEL), a
        ld de, near_n
        ld b, 2
        call st_copy                ; the near walls
        ld de, areas
        ld bc, 5
        ldir
        ld de, spr_n
        ld b, 4
        call st_copy                ; the objects
        ld de, door_n
        ld b, 4
        call st_copy                ; the doors
        ld (st_farp), hl
        ld a, 1
        ld (BANK2_SEL), a
        ; the near strips: vertices and faces from 0
        ld hl, ncorner
        ld b, 16
        ld a, 0xFF
sb_2:   ld (hl), a
        inc hl
        djnz sb_2
        xor a
        ld (st_nv), a
        ld (st_nf), a
        call st_ptrs
        ld a, (near_n)
        or a
        jr z, sb_4
        ld b, a
        ld iy, nearbuf
        ld hl, nearab
        ld (nab_ptr), hl
        ld hl, nwall
sb_3:   push bc
        push hl
        call ns_wall
        ; nearab: where the high bytes of the corners' depths are in zgrid
        ld a, (ne_dir)
        ld e, a
        ld d, 0
        ld hl, ne_ofs
        add hl, de
        ld c, (hl)                  ; corner B from corner A
        ld hl, (nab_ptr)
        ld a, (ne_ia)
        add a, a
        add a, 1 + (zgrid & 255)
        ld (hl), a
        inc hl
        add a, c
        ld (hl), a
        inc hl
        ld (nab_ptr), hl
        pop hl
        ld de, 5
        add hl, de
        inc iy
        inc iy
        pop bc
        djnz sb_3
sb_4:   ld a, (st_nv)
        ld (near_nv), a
        ld a, (st_nf)
        ld (near_nf), a
        ; fall through

; the far faces for this yaw and these doors, after the near strips; then
; the objects
st_far: ld a, (p_yaw)
        ld (st_yaw), a
        xor a
        ld (st_dirty), a
        ; the corners of the last build leave cornermap
        ld a, (cm_n)
        or a
        jr z, sfc_2
        ld b, a
        ld hl, cm_list
sfc_1:  ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld a, 0xFF
        ld (de), a
        djnz sfc_1
        xor a
        ld (cm_n), a
sfc_2:
        ld a, (near_nv)
        ld (st_nv), a
        ld a, (near_nf)
        ld (st_nf), a
        call st_ptrs
        ld a, (st_bank)
        ld (BANK2_SEL), a
        ld hl, (st_farp)
        ld a, (hl)
        inc hl
        or a
        jr z, sb_done
        ld b, a
        push hl
        pop ix
sb_loop:
        push bc
        ld a, (st_yaw)
        sub (ix + 3)
        ld c, a
        ld a, (ix + 4)
        cp c
        jr c, sb_next               ; lim < yaw - a0: out of view
        ld a, (ix + 5)
        call dep_shut
        jr nz, sb_next              ; behind a shut door
        ld a, (st_nv)
        cp VMAX_STATIC - 5
        jr nc, sb_stop
        ld a, (st_nf)
        cp FMAX_STATIC - 1
        jr nc, sb_stop
        call sb_face
sb_next:
        ld de, 6
        add ix, de
        pop bc
        djnz sb_loop
        jr sb_done
sb_stop:
        pop bc
sb_done:
        ld a, 1
        ld (BANK2_SEL), a
        ; fall through

; the objects in sight as billboards turned to this yaw, nearest first,
; until VMAX_SPR vertices are in use
ob_build:
        ld a, (p_yaw)
        ld (ob_yaw), a
        xor a
        ld (ob_dirty), a
        ld a, (st_nv)
        ld (dn_v), a
        ld a, (st_nf)
        ld (dn_f), a
        call st_ptrs
        ld hl, 0
        ld (bb_hw), hl
        ld a, (spr_n)
        or a
        jr z, ob_done
        ld b, a
        ld iy, sprbuf
ob_loop:
        push bc
        ld a, (ob_yaw)
        sub (iy + 1)
        ld c, a
        ld a, (iy + 2)
        cp c
        jr c, ob_next
        ld a, (iy + 3)
        call dep_shut
        jr nz, ob_next
        ld a, (iy + 0)
        call obj_taken
        jr nz, ob_next
        ld a, (dn_v)
        cp VMAX_SPR - 3
        jr nc, ob_stop
        ld a, (dn_f)
        cp 251
        jr nc, ob_stop
        ; obj_tab: cell x, z, frame, kind
        ld l, (iy + 0)
        ld h, 0
        add hl, hl
        add hl, hl
        ld de, obj_tab
        add hl, de
        ld d, (hl)
        ld e, 128
        inc hl
        ld b, (hl)
        inc hl
        ld a, (hl)
        ld h, b
        ld l, 128
        push iy
        call bb_emit
        pop iy
ob_next:
        ld de, 4
        add iy, de
        pop bc
        djnz ob_loop
        jr ob_done
ob_stop:
        pop bc
ob_done:
        ld a, (dn_v)
        ld (ob_nv), a
        ld a, (dn_f)
        ld (ob_nf), a
        ret

; HL -> db count, entries of B bytes; DE -> the same in RAM -> HL after them
st_copy:
        ld a, (hl)
        inc hl
        ld (de), a
        inc de
        or a
        ret z
        ld c, a
        xor a
sy_1:   add a, c
        djnz sy_1
        ld c, a
        ld b, 0
        ldir
        ret

; A = dep -> NZ if it is a door's number + 1 and that door is shut
dep_shut:
        or a
        ret z
        dec a
        ld e, a
        ld d, 0
        ld hl, door_pos
        add hl, de
        ld a, (hl)
        or a
        jr z, dps_1
        xor a
        ret
dps_1:   inc a
        ret

; A = object -> NZ if the player has taken it
obj_taken:
        ld c, a
        rrca
        rrca
        rrca
        and 31
        ld e, a
        ld d, 0
        ld hl, taken
        add hl, de
        ld a, c
        and 7
        ld e, a
        ld a, (hl)
        ld hl, bit_tab
        add hl, de
        and (hl)
        ret
bit_tab:
        db 1, 2, 4, 8, 16, 32, 64, 128

; geo3d's write pointers: vertices at st_nv, faces and texture points at st_nf
st_ptrs:
        ld a, 0x40
        out (GEO_IDX), a
        ld a, (st_nv)
        out (GEO_DAT), a            ; VADDR
        ld a, 0x58
        out (GEO_IDX), a
        ld a, (st_nf)
        out (GEO_DAT), a            ; FADDR
        ld a, 0x65
        out (GEO_IDX), a
        ld a, (st_nf)
        out (GEO_DAT), a            ; TADDR
        ret

; the same for the frame's own faces: after the objects
dn_ptrs:
        ld a, 0x40
        out (GEO_IDX), a
        ld a, (ob_nv)
        ld (dn_v), a
        out (GEO_DAT), a
        ld a, 0x58
        out (GEO_IDX), a
        ld a, (ob_nf)
        ld (dn_f), a
        out (GEO_DAT), a
        ld a, 0x65
        out (GEO_IDX), a
        ld a, (ob_nf)
        out (GEO_DAT), a
        ret

; A = texture | dark << 4 (texture 0..11): its band -> fc_ny, its column -> A
tex_set:
        ld c, a
        rrca
        rrca
        and 3                       ; texture / 4
        bit 4, c
        jr z, ts_1
        add a, 3
ts_1:   call ny_get
        ld a, c
        and 3
        rrca
        rrca                        ; 64 * (texture & 3)
        ret

; A = band -> fc_ny (keeps BC)
ny_get: add a, a
        ld e, a
        ld d, 0
        ld hl, ny_tab
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ld (fc_ny), hl
        ret

; IY -> a near entry, HL -> its record in nwall (the top vertices at 0, 64,
; 128, 192 and 256 units along the wall): its two corners (shared with the
; other near walls through ncorner), three pairs inside, four faces
ns_wall:
        ld (nw_ptr), hl
        ld a, (iy + 0)
        and 15
        ld (ne_ia), a
        call ncv_get
        ld hl, (nw_ptr)
        ld (hl), a
        ld a, (iy + 0)
        rrca
        rrca
        rrca
        rrca
        and 3
        ld (ne_dir), a
        ld e, a
        ld d, 0
        ld hl, ncv_ofs
        add hl, de
        ld a, (ne_ia)
        add a, (hl)
        call ncv_get
        ld hl, (nw_ptr)
        ld de, 4
        add hl, de
        ld (hl), a
        call ne_world
        call wall_y
        ld a, 0x50
        out (GEO_IDX), a
        ld b, 3
        ld hl, (nw_ptr)
nsw_1:  inc hl
        push bc
        push hl
        ld de, 64
        call ne_step
        call vtx_pair
        pop hl
        ld a, (st_nv)
        ld (hl), a
        add a, 2
        ld (st_nv), a
        pop bc
        djnz nsw_1
        ld a, (iy + 1)
        call tex_set
        ld (fc_u0), a
        call wall_v
        ld b, 4
        ld hl, (nw_ptr)
nsw_2:  push bc
        ld a, (hl)
        ld (fc_a), a
        inc hl
        ld a, (hl)
        ld (fc_b), a
        push hl
        ld a, (fc_u0)
        add a, 15
        ld (fc_u1), a
        call face_out
        ld a, (fc_u0)
        add a, 16
        ld (fc_u0), a
        ld hl, st_nf
        inc (hl)
        pop hl
        pop bc
        djnz nsw_2
        ret

ncv_ofs:
        db 1, 255, 4, 252           ; corner B in ncorner: +x, -x, +z, -z

; bb_y1, bb_y0 = a wall's top and bottom
wall_y: ld hl, WALL_H
        ld (bb_y1), hl
        ld hl, 0
        ld (bb_y0), hl
        ret

; fc_v0, fc_v1 = a wall texture's rows
wall_v: xor a
        ld (fc_v0), a
        ld a, 63
        ld (fc_v1), a
        ret

; A = i + 4 j, a corner around the cell -> A = its top vertex (new ones go
; to geo3d)
ncv_get:
        ld e, a
        ld d, 0
        ld hl, ncorner
        add hl, de
        ld a, (hl)
        cp 0xFF
        ret nz
        ld a, (st_nv)
        ld (hl), a
        add a, 2
        ld (st_nv), a
        ld a, e
        and 3
        ld b, a
        ld a, (st_cx)
        dec a
        add a, b
        ld b, a
        ld a, e
        rrca
        rrca
        and 3
        ld c, a
        ld a, (st_cz)
        dec a
        add a, c
        ld c, a
        ld e, (hl)
        jp cv_emit

; IY -> a near entry: corner A in the world -> ne_ax, ne_az, ne_vx, ne_vz
ne_world:
        ld a, (iy + 0)
        and 3
        ld b, a
        ld a, (st_cx)
        dec a
        add a, b
        ld h, a
        ld l, 0
        ld (ne_ax), hl
        ld (ne_vx), hl
        ld a, (iy + 0)
        rrca
        rrca
        and 3
        ld b, a
        ld a, (st_cz)
        dec a
        add a, b
        ld h, a
        ld l, 0
        ld (ne_az), hl
        ld (ne_vz), hl
        ret

; (ne_vx, ne_vz) += DE units along the wall (ne_dir)
ne_step:
        ld a, (ne_dir)
        or a
        jr z, nst_px
        dec a
        jr z, nst_mx
        dec a
        jr z, nst_pz
        ld hl, (ne_vz)
        or a
        sbc hl, de
        ld (ne_vz), hl
        ret
nst_px: ld hl, (ne_vx)
        add hl, de
        ld (ne_vx), hl
        ret
nst_mx: ld hl, (ne_vx)
        or a
        sbc hl, de
        ld (ne_vx), hl
        ret
nst_pz: ld hl, (ne_vz)
        add hl, de
        ld (ne_vz), hl
        ret

; IX -> a far entry: its two corners' vertices (new ones go to geo3d), the
; face and its texture points
sb_face:
        ld b, (ix + 0)
        ld c, (ix + 1)
        call corner_vtx
        ld (fc_a), a
        ld b, (ix + 0)
        ld c, (ix + 1)
        ld a, (ix + 2)
        and 3
        jr z, sf_px
        dec a
        jr z, sf_mx
        dec a
        jr z, sf_pz
        dec c
        jr sf_b
sf_px:  inc b
        jr sf_b
sf_mx:  dec b
        jr sf_b
sf_pz:  inc c
sf_b:   call corner_vtx
        ld (fc_b), a
        ; texture | dark << 4 from bits 2-5 and 6
        ld a, (ix + 2)
        rrca
        rrca
        and 0x1F
        call tex_set
        ld (fc_u0), a
        add a, 63
        ld (fc_u1), a
        call wall_v
        bit 7, (ix + 2)
        jr nz, sf_two
        call face_out
        ld hl, st_nf
        inc (hl)
        ret
; two halves: a pair of vertices in the middle of the wall
sf_two: ld h, (ix + 0)
        ld l, 0
        ld (ne_vx), hl
        ld h, (ix + 1)
        ld (ne_vz), hl
        ld a, (ix + 2)
        and 3
        ld (ne_dir), a
        ld de, 128
        call ne_step
        call wall_y
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (fc_b)
        ld (tmp), a                 ; corner B
        ld a, (st_nv)
        ld (fc_b), a                ; the middle
        add a, 2
        ld (st_nv), a
        ld a, (fc_u0)
        add a, 31
        ld (fc_u1), a
        call face_out               ; A .. middle: u 0..31
        ld a, (fc_b)
        ld (fc_a), a
        ld a, (tmp)
        ld (fc_b), a
        ld a, (fc_u0)
        add a, 32
        ld (fc_u0), a
        add a, 31
        ld (fc_u1), a
        call face_out               ; middle .. B: u 32..63
        ld hl, st_nf
        inc (hl)
        inc (hl)
        ret

; B = corner x, C = corner z (map cells, within WIN of the build cell)
; -> A = its top vertex (a new pair goes to geo3d). cornermap is 32 x 32
; corners that wrap around (the window is narrower): entry 32 (z & 31) +
; (x & 31) has the corner's top vertex, FFh if it has none yet. cm_list
; remembers the entries in use, for st_far to free them.
corner_vtx:
        ld a, c
        rrca
        rrca
        rrca
        ld h, a
        and 0xE0
        ld l, a
        ld a, b
        and 31
        or l
        ld l, a
        ld a, h
        and 3
        ld h, a
        ld de, cornermap
        add hl, de
        ld a, (hl)
        cp 0xFF
        ret nz
        ex de, hl                   ; a new one: DE -> its entry
        ld a, (cm_n)
        ld l, a
        inc a
        ld (cm_n), a
        ld h, 0
        add hl, hl
        push bc
        ld bc, cm_list
        add hl, bc
        pop bc
        ld (hl), e
        inc hl
        ld (hl), d
        ld a, (st_nv)
        ld (de), a
        ld e, a
        add a, 2
        ld (st_nv), a
; B = corner x, C = corner z, E = vertex: the pair goes to geo3d -> A = E
cv_emit:
        ld a, 0x50
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a            ; x = 256 * B
        ld a, b
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; y = 256 (WALL_H)
        inc a
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; z = 256 * C
        ld a, c
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a
        ld a, b
        out (GEO_DAT), a
        xor a
        out (GEO_DAT), a            ; y = 0
        out (GEO_DAT), a
        out (GEO_DAT), a
        ld a, c
        out (GEO_DAT), a
        ld a, e
        ret

; the face (fc_a, fc_b, fc_b + 1, fc_a + 1), normal (0, fc_ny, 0), textured,
; and its texture points (fc_u0, fc_v0) .. (fc_u1, fc_v1)
; (uses A, C, DE, HL)
face_out:
        ld a, 0x52
        out (GEO_IDX), a
        ld c, GEO_DAT
        ld hl, (fc_a)               ; L = fc_a, H = fc_b
        out (c), l
        out (c), h
        inc h
        out (c), h
        inc l
        out (c), l
        xor a
        out (c), a
        out (c), a                  ; NX
        ld hl, (fc_ny)
        out (c), l
        out (c), h                  ; NY
        out (c), a
        out (c), a                  ; NZ
        ld a, 0x80
        out (c), a                  ; BASE: textured
        ld a, 0x53
        out (GEO_IDX), a
        ld hl, (fc_u0)              ; L = u0, H = u1
        ld de, (fc_v0)              ; E = v0, D = v1
        out (c), l
        out (c), e
        out (c), h
        out (c), e
        out (c), h
        out (c), d
        out (c), l
        out (c), d
        ret

; ---------------------------------------------------------------- near faces
; zgrid[i + 4 j] = 32 * camera Z of the grid corner (cx - 1 + i, cz - 1 + j):
; two multiplies for the first one, then adds (a cell east adds fx / 2, a
; cell south fz / 2).
near_emit:
        ld a, (p_x)
        ld l, a
        ld h, 1                     ; 256 + the fraction of x
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        call neg_hl
        ex de, hl                   ; DE = 32 * (corner x - player x)
        ld bc, (cam_fx)
        call mulq14
        push hl
        ld a, (p_z)
        ld l, a
        ld h, 1
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        add hl, hl
        call neg_hl
        ex de, hl
        ld bc, (cam_fz)
        call mulq14
        pop de
        add hl, de
        ld (ne_row), hl
        ld hl, (cam_fx)
        sra h
        rr l
        ld (ne_sx), hl
        ld hl, (cam_fz)
        sra h
        rr l
        ld (ne_sz), hl
        ld ix, zgrid
        ld c, 4
gf_j:   ld hl, (ne_row)
        ld de, (ne_sx)
        ld b, 4
gf_i:   ld (ix + 0), l
        ld (ix + 1), h
        inc ix
        inc ix
        add hl, de
        djnz gf_i
        ld hl, (ne_row)
        ld de, (ne_sz)
        add hl, de
        ld (ne_row), hl
        dec c
        jr nz, gf_j
        ; this frame's vertices and faces go after the objects
        call dn_ptrs
        ld a, (near_n)
        or a
        ret z
        ; only a wall with one corner in front of Z = ZCLIP and one behind
        ; has work to do: nearab has, for each wall, where the high bytes of
        ; its corners' depths are in zgrid (which is inside one page of RAM)
        ld b, a
        ld de, nearab
        ld h, zgrid >> 8
ne_loop:
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        sub ZCLIP32 >> 8
        ld c, a
        ld a, (de)
        inc de
        ld l, a
        ld a, (hl)
        sub ZCLIP32 >> 8
        xor c
        jp m, ne_cross
ne_next:
        djnz ne_loop
        ret
ne_cross:
        push bc
        push de
        ld a, (near_n)
        sub b                       ; the wall's number
        ld l, a
        ld h, 0
        ld e, l
        ld d, h
        add hl, hl
        push hl
        add hl, hl
        add hl, de
        ld de, nwall
        add hl, de
        ld (nw_ptr), hl             ; nwall + 5 n
        pop hl
        ld de, nearbuf
        add hl, de
        push hl
        pop iy                      ; nearbuf + 2 n
        call ne_wall
        call bg_try
        pop de
        pop bc
        ld h, zgrid >> 8
        jr ne_next

ne_ofs: db 2, 254, 8, 248           ; corner B in zgrid: +x, -x, +z, -z

; HL -> grid, A = byte offset -> HL = the word there
grid_get:
        ld e, a
        ld d, 0
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ret

; ne_za, ne_zb: the depths of the ends A and B of a line 256 units long.
; The part in front of Z = ZCLIP -> ne_o (0..255) .. ne_e (1..256), NC; or
; C if there is none.
clip_range:
        ld hl, 0
        ld (ne_o), hl
        ld hl, 256
        ld (ne_e), hl
        ld de, 0 - ZCLIP32
        ld hl, (ne_zb)
        add hl, de
        ld a, h
        and 0x80
        ld b, a
        ld hl, (ne_za)
        add hl, de
        ld a, h
        and 0x80
        ld c, a
        or b
        ret z                       ; all in front (NC)
        ld a, c
        and b
        jr nz, cr_none              ; all behind
        ld a, c
        or a
        jr z, cr_b
        ; A behind: from o = frac(ZCLIP - za, zb - za) + 1
        ld hl, (ne_zb)
        ld de, (ne_za)
        or a
        sbc hl, de
        push hl
        ld hl, ZCLIP32
        or a
        sbc hl, de
        pop de
        call frac8
        inc a
        jr z, cr_none
        ld (ne_o), a
        or a
        ret
cr_b:   ; B behind: up to e = 255 - frac(ZCLIP - zb, za - zb)
        ld hl, (ne_za)
        ld de, (ne_zb)
        or a
        sbc hl, de
        push hl
        ld hl, ZCLIP32
        or a
        sbc hl, de
        pop de
        call frac8
        cpl
        or a
        jr z, cr_none
        ld l, a
        ld h, 0
        ld (ne_e), hl
        or a
        ret
cr_none:
        scf
        ret

; IY -> a near entry, nw_ptr -> its record: if the wall crosses Z = ZCLIP,
; the face from the crossing to the end of the strip it falls in
ne_wall:
        ld a, (iy + 0)
        and 15
        add a, a
        ld (ne_ia), a
        ld hl, zgrid
        call grid_get
        ld (ne_za), hl
        ld a, (iy + 0)
        rrca
        rrca
        rrca
        rrca
        and 3
        ld (ne_dir), a
        ld e, a
        ld d, 0
        ld hl, ne_ofs
        add hl, de
        ld a, (ne_ia)
        add a, (hl)
        ld hl, zgrid
        call grid_get
        ld (ne_zb), hl
        call clip_range
        ret c                       ; all behind
        ld hl, (ne_o)
        ld a, l
        or a
        jr nz, nw_a
        ld a, (ne_e + 1)
        or a
        ret nz                      ; all in front
        ; B behind: from the start of the strip to the crossing
        ld a, (dn_v)
        cp 254
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        call nw_set
        ld a, (ne_e)
        ld e, a
        ld d, 0
        call ne_step
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (dn_v)
        ld (fc_b), a                ; .. to the crossing
        add a, 2
        ld (dn_v), a
        ld a, (ne_e)
        dec a
        ld b, a
        rlca
        rlca
        and 3
        ld c, a                     ; the strip: (e - 1) / 64
        ld hl, (nw_ptr)
        ld e, a
        ld d, 0
        add hl, de
        ld a, (hl)
        ld (fc_a), a                ; from the strip's near end ..
        ld a, c
        add a, a
        add a, a
        add a, a
        add a, a
        ld d, a
        ld a, (ne_u)
        add a, d
        ld (fc_u0), a
        ld a, b
        srl a
        srl a
        ld d, a
        ld a, (ne_u)
        add a, d
        ld (fc_u1), a
        jr nw_f
nw_a:   ; A behind: from the crossing to the end of the strip
        ld a, (dn_v)
        cp 254
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        call nw_set
        ld a, (ne_o)
        ld e, a
        ld d, 0
        call ne_step
        ld a, 0x50
        out (GEO_IDX), a
        call vtx_pair
        ld a, (dn_v)
        ld (fc_a), a                ; the crossing ..
        add a, 2
        ld (dn_v), a
        ld a, (ne_o)
        rlca
        rlca
        and 3
        ld c, a                     ; the strip: o / 64
        ld hl, (nw_ptr)
        ld e, a
        ld d, 0
        add hl, de
        inc hl
        ld a, (hl)
        ld (fc_b), a                ; .. to the strip's far end
        ld a, (ne_o)
        srl a
        srl a
        ld b, a
        ld a, (ne_u)
        add a, b
        ld (fc_u0), a
        ld a, c
        add a, a
        add a, a
        add a, a
        add a, a
        add a, 15
        ld b, a
        ld a, (ne_u)
        add a, b
        ld (fc_u1), a
nw_f:   call face_out
        ld hl, dn_f
        inc (hl)
        ret

; IY -> a near entry: corner A, the wall's texture and height, ready to emit
nw_set: call ne_world
        ld a, (iy + 1)
        call tex_set
        ld (ne_u), a
        call wall_v
        jp wall_y

; (ne_vx, bb_y1, ne_vz) and (ne_vx, bb_y0, ne_vz) -> the vertex stream
; (index 50h already selected)
vtx_pair:
        ld hl, (ne_vx)
        ld de, (ne_vz)
        ld c, GEO_DAT
        out (c), l
        out (c), h
        ld a, (bb_y1)
        out (c), a
        ld a, (bb_y1 + 1)
        out (c), a
        out (c), e
        out (c), d
        out (c), l
        out (c), h
        ld a, (bb_y0)
        out (c), a
        ld a, (bb_y0 + 1)
        out (c), a
        out (c), e
        out (c), d
        ret

; ---------------------------------------------------------------- doors
; A door is a face in the middle of its cell. It slides south (a vertical
; door: its plane runs north-south) or east into the wall: at position pos
; (0 shut .. 255) it goes from pos to 256 along the cell, with the texture
; moving with it. doorbuf has the doors in sight of the cell: number, a0,
; lim, dep. The ones in the 3 x 3 cells around the player are cut at
; Z = ZCLIP like the near walls.
dr_emit:
        ld a, (door_n)
        or a
        ret z
        ld b, a
        ld iy, doorbuf
dr_loop:
        push bc
        call dr_one
        call bg_try
        ld de, 4
        add iy, de
        pop bc
        djnz dr_loop
        ret

dr_one: ld e, (iy + 0)
        ld d, 0
        ld hl, door_pos
        add hl, de
        ld a, (hl)
        cp DOOR_GONE
        ret nc                      ; open: nothing to draw
        ld (dr_pos), a
        ld a, (p_yaw)
        sub (iy + 1)
        ld c, a
        ld a, (iy + 2)
        cp c
        ret c                       ; out of view
        ld a, (iy + 3)
        call dep_shut
        ret nz
        ld a, (dn_v)
        cp 252
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        ; door_tab: cell x, z, vertical, texture
        ld l, (iy + 0)
        ld h, 0
        add hl, hl
        add hl, hl
        ld de, door_tab
        add hl, de
        ld a, (hl)
        ld (dr_x), a
        inc hl
        ld a, (hl)
        ld (dr_z), a
        inc hl
        ld a, (hl)
        ld (dr_v), a
        inc hl
        ld a, (hl)
        ld (dr_t), a
        ; lo = pos, hi = 256
        ld a, (dr_pos)
        ld l, a
        ld h, 0
        ld (dr_lo), hl
        ld hl, 256
        ld (dr_hi), hl
        ; in the 3 x 3 cells around the player?
        ld a, (p_cx)
        ld b, a
        ld a, (dr_x)
        sub b
        inc a
        cp 3
        jr nc, dr_far
        ld c, a                     ; i
        ld a, (p_cz)
        ld b, a
        ld a, (dr_z)
        sub b
        inc a
        cp 3
        jr nc, dr_far
        add a, a
        add a, a
        add a, c
        add a, a                    ; 2 (i + 4 j): the cell's north-west corner
        ld c, a
        ; the depths of the ends of the door's line: each the mean of two corners
        ld a, (dr_v)
        or a
        ld de, 0x0802               ; vertical: (nw, ne) and (sw, se)
        jr nz, dr_1
        ld de, 0x0208               ; horizontal: (nw, sw) and (ne, se)
dr_1:   ld a, c
        call dr_mean
        ld (ne_za), hl
        ld a, c
        add a, d
        call dr_mean
        ld (ne_zb), hl
        call clip_range
        ret c
        ; lo = max(lo, o), hi = min(hi, e)
        ld hl, (dr_lo)
        ld de, (ne_o)
        or a
        sbc hl, de
        jr nc, dr_2
        ld (dr_lo), de
dr_2:   ld hl, (ne_e)
        ld de, (dr_hi)
        or a
        sbc hl, de
        jr nc, dr_3
        ld hl, (ne_e)
        ld (dr_hi), hl
dr_3:   ld hl, (dr_lo)
        ld de, (dr_hi)
        or a
        sbc hl, de
        ret nc                      ; nothing left
dr_far: ; texture: band and column; u at lo and at hi
        ld a, (dr_v)
        or a
        ld a, (dr_t)
        jr z, dr_4
        or 0x10                     ; a vertical door is a dark face
dr_4:   call tex_set
        ld c, a
        ld a, (dr_pos)
        ld b, a
        ld a, (dr_lo)
        sub b
        srl a
        srl a
        add a, c
        ld (dr_ulo), a
        ld hl, (dr_hi)
        dec hl
        ld a, l
        sub b
        srl a
        srl a
        add a, c
        ld (dr_uhi), a
        call wall_v
        call wall_y
        ; which end is on the left? vertical: the low (north) one from the
        ; west; horizontal: the low (west) one from the south
        ld a, (dr_v)
        or a
        jr z, dr_h
        ld a, (dr_x)
        ld h, a
        ld l, 128
        ld (ne_vx), hl
        ex de, hl
        ld hl, (p_x)
        or a
        sbc hl, de                  ; C: the player is west of the door
        jr dr_5
dr_h:   ld a, (dr_z)
        ld h, a
        ld l, 128
        ld (ne_vz), hl
        ld de, (p_z)
        or a
        sbc hl, de                  ; C: the player is south of the door
dr_5:   ld a, 0x50
        out (GEO_IDX), a
        jr nc, dr_6
        ; low end first
        ld hl, (dr_lo)
        call dr_vtx
        ld hl, (dr_hi)
        call dr_vtx
        ld a, (dr_ulo)
        ld (fc_u0), a
        ld a, (dr_uhi)
        ld (fc_u1), a
        jr dr_7
dr_6:   ld hl, (dr_hi)
        call dr_vtx
        ld hl, (dr_lo)
        call dr_vtx
        ld a, (dr_uhi)
        ld (fc_u0), a
        ld a, (dr_ulo)
        ld (fc_u1), a
dr_7:   ld a, (dn_v)
        ld (fc_a), a
        add a, 2
        ld (fc_b), a
        add a, 2
        ld (dn_v), a
        call face_out
        ld hl, dn_f
        inc (hl)
        ret

; A = offset in zgrid, E = offset of the second corner from it
; -> HL = half of one plus half of the other (keeps BC, DE)
dr_mean:
        push de
        push af
        ld hl, zgrid
        call grid_get
        sra h
        rr l
        pop af
        pop de
        push de
        push hl
        add a, e
        ld hl, zgrid
        call grid_get
        sra h
        rr l
        pop de
        add hl, de
        pop de
        ret

; HL = offset along the door's line (0..256): the pair of vertices there
dr_vtx: ex de, hl
        ld a, (dr_v)
        or a
        jr z, dv_h
        ld a, (dr_z)
        ld h, a
        ld l, 0
        add hl, de
        ld (ne_vz), hl
        jp vtx_pair
dv_h:   ld a, (dr_x)
        ld h, a
        ld l, 0
        add hl, de
        ld (ne_vx), hl
        jp vtx_pair

; ---------------------------------------------------------------- billboards
; A = frame (frame_tab), DE = x, HL = z: a face turned to the camera
bb_emit:
        ld (bb_x), de
        ld (bb_z), hl
        ld b, a
        ld a, (dn_v)
        cp 252
        ret nc
        ld a, (dn_f)
        cp 255
        ret nc
        ld l, b
        ld h, 0
        add hl, hl
        add hl, hl
        ld e, l
        ld d, h
        add hl, hl
        add hl, de                  ; 12 bytes a frame
        ld de, frame_tab
        add hl, de
        push hl
        pop ix
        ld a, (ix + 0)
        ld (fc_u0), a
        add a, (ix + 2)
        ld (fc_u1), a
        ld a, (ix + 1)
        ld (fc_v0), a
        add a, (ix + 3)
        ld (fc_v1), a
        ld l, (ix + 4)
        ld h, (ix + 5)
        ld (fc_ny), hl
        ld l, (ix + 8)
        ld h, (ix + 9)
        ld (bb_y0), hl
        ld l, (ix + 10)
        ld h, (ix + 11)
        ld (bb_y1), hl
        ld e, (ix + 6)
        ld d, (ix + 7)              ; half the width
        ld hl, (bb_hw)
        or a
        sbc hl, de
        jr z, bb_1                  ; the same as the last one
        ld (bb_hw), de
        push de
        ld bc, (cam_rx)
        call mulq14
        ld (bb_ox), hl
        pop de
        ld bc, (cam_rz)
        call mulq14
        ld (bb_oz), hl
bb_1:   ld a, 0x50
        out (GEO_IDX), a
        ld hl, (bb_x)
        ld de, (bb_ox)
        or a
        sbc hl, de
        ld (ne_vx), hl
        ld hl, (bb_z)
        ld de, (bb_oz)
        or a
        sbc hl, de
        ld (ne_vz), hl
        call vtx_pair               ; the left side
        ld hl, (bb_x)
        ld de, (bb_ox)
        add hl, de
        ld (ne_vx), hl
        ld hl, (bb_z)
        ld de, (bb_oz)
        add hl, de
        ld (ne_vz), hl
        call vtx_pair               ; the right side
        ld a, (dn_v)
        ld (fc_a), a
        add a, 2
        ld (fc_b), a
        add a, 2
        ld (dn_v), a
        call face_out
        ld hl, dn_f
        inc (hl)
        ret

; B = cx, C = cz of a monster or a loose item -> NZ if it is drawn: within
; WIN cells and in a door or an area the player's cell sees
area_seen:
        ld a, (p_cx)
        sub b
        add a, WIN
        cp WIN_W
        jr nc, as_no
        ld a, (p_cz)
        sub c
        add a, WIN
        cp WIN_W
        jr nc, as_no
        call grid_at
        ld c, a
        and 0xC0
        cp 0x80
        jr z, as_yes
        ld a, c
        and 63
        cp 40
        jr nc, as_no
        ld c, a
        rrca
        rrca
        rrca
        and 7
        ld e, a
        ld d, 0
        ld hl, areas
        add hl, de
        ld a, c
        and 7
        ld e, a
        ld a, (hl)
        ld hl, bit_tab
        add hl, de
        and (hl)
        ret
as_yes: or 1
        ret
as_no:  xor a
        ret

; ---------------------------------------------------------------- RUN
; the counts, the page, the camera, RUN (faces, textures)
geo_run:
        ld a, 0x42
        out (GEO_IDX), a
        ld a, (dn_v)
        out (GEO_DAT), a            ; NVERT
        ld (st_nvert), a
        ld a, 0x59
        out (GEO_IDX), a
        ld a, (dn_f)
        out (GEO_DAT), a            ; NFACE
        ld (st_nface), a
        ld a, 0x46
        out (GEO_IDX), a
        xor a
        out (GEO_DAT), a
        ld a, (buf)
        out (GEO_DAT), a            ; YPAGE = 256 * buf
        xor a
        out (GEO_IDX), a
        ld hl, cambuf
        ld bc, 24 * 256 + GEO_DAT
        otir
        ld a, 0x48
        out (GEO_IDX), a
        ld a, 7
        out (GEO_DAT), a
        ret

; ---------------------------------------------------------------- background
; the ceiling and the floor: two fills of the hidden page (as Wolfenstein
; 3D does), their 11 command bytes (R#36..R#46) ready in bg_cmds for each page
; A fill takes the V9968 1.6 ms and may only start when the frame before
; is on show (the hidden page is free then), so the frame calls bg_try
; between the parts of its geometry and bg_rest after them.

; start the next fill if the page is free and the V9968 idle; never waits
; (keeps IX, IY)
bg_try: ld a, (bg_n)
        cp NBANDS
        ret nc
        ld a, (flip_pend)
        or a
        jr z, bt_1
        ld a, (flip_req)
        or a
        ret nz                      ; the vertical blank has not come yet
        call flip_sync              ; (at once)
bt_1:   ld a, 2
        call rd_status
        rrca
        ret c                       ; the fill before is running
bt_2:   ld a, (bg_n)
        call bg_band
        ld hl, bg_n
        inc (hl)
        ret

; the fills not started yet: waits for the vertical blank and the V9968
bg_rest:
        call flip_sync
br_1:   ld a, (bg_n)
        cp NBANDS
        ret nc
        call bt_2
        jr br_1

; A = 0 the ceiling, 1 the floor: its fill, when the V9968 is idle
bg_band:
        ld hl, bg_cmds
        or a
        jr z, bg_0
        ld hl, bg_cmds + 11
bg_0:   ld a, (buf)
        or a
        jr z, bg_1
        ld de, NBANDS * 11
        add hl, de
bg_1:   push hl
        call wait_ce
        ld a, 36
        ld b, 17
        call wreg
        pop hl
        ld bc, 11 * 256 + VDP_IND
        otir
        ret

; ---------------------------------------------------------------- overlays
; the pistol, over the 3D picture: its two frames are in the rows of page 1
; that are never shown, 64 x 88 each as two pieces of 44 rows side by side
; (LMMM + TIMP). gun_y lowers it (it bobs, and drops when the player dies).
ov_draw:
        ld a, (gun_y)
        cp 76
        ret nc                      ; out of sight
        ; the upper piece: rows 0..43, or what fits
        ld a, (gun_f)
        rrca                        ; 128 * frame
        ld l, a
        ld h, 0
        ld (cmd_sx), hl
        ld hl, PISTOL_ROW
        ld (cmd_sy), hl
        ld a, (gun_x)
        ld l, a
        ld h, 0
        ld (cmd_dx), hl
        ld a, (gun_y)
        add a, G3_H - 76
        ld l, a
        ld a, (buf)
        ld h, a
        ld (cmd_dy), hl
        ld hl, 64
        ld (cmd_nx), hl
        ld a, (gun_y)
        ld b, a
        ld a, 76
        sub b                       ; rows on show
        cp 45
        jr c, ov_1
        ld a, 44
ov_1:   ld l, a
        ld h, 0
        ld (cmd_ny), hl
        call ov_copy
        ; the lower piece: rows 44..
        ld a, (gun_y)
        cp 32
        ret nc
        ld b, a
        ld a, 32
        sub b
        ld l, a
        ld h, 0
        ld (cmd_ny), hl
        ld hl, (cmd_sx)
        ld de, 64
        add hl, de
        ld (cmd_sx), hl
        ld hl, (cmd_dy)
        ld de, 44
        add hl, de
        ld (cmd_dy), hl
        ; fall through
ov_copy:
        xor a
        ld (cmd_clr), a
        ld (cmd_arg), a
        ld a, LMMM + TIMP
        ld (cmd_op), a
        jp cmd_all

; ---------------------------------------------------------------- the flip
; flip_ask: show the page just drawn at the next vertical blank. flip_sync:
; wait for that and take the other page for drawing. Between the two the
; Z80 may do anything but draw: the next frame's geometry is worked out.
flip:   call flip_ask
        ; fall through
flip_sync:
        ld a, (flip_pend)
        or a
        ret z
        xor a
        ld (flip_pend), a
        ld bc, 0                    ; (no interrupt in about 1 s: flip here)
fl_1:   ld a, (flip_req)
        or a
        jr z, fl_2
        dec bc
        ld a, b
        or c
        jr nz, fl_1
        ld (flip_req), a
        ld a, (flip_r2)
        ld b, 2
        call wreg
        jr fl_2
flip_ask:
        call wait_ce
        ld a, (buf)
        rrca
        rrca
        rrca
        or 0x1F
        ld (flip_r2), a
        ld a, 1
        ld (flip_pend), a
        ld (flip_req), a
        ret
fl_2:   ld a, (buf)
        xor 1
        ld (buf), a
        ret
