; ============================================================================
; game.asm - the game loop, the player, doors, the shot, pickups
;
; Time: the frame rate follows the picture, so everything moves by `dt`, the
; number of vertical blanks (1/60 s) the last frame took, 1 to 8.
; Positions are 16 bits, 256 units a cell: the high byte is the cell.
; A frame (frame): palette; the faces to geo3d while the frame before waits
; for its vertical blank; background, RUN; while geo3d and the V9968 draw,
; the game logic of the next frame; then the pistol, the status bar and the
; request to show the page. The Z80 only waits when it is ahead.
; ============================================================================

ST_PLAY:    equ 0
ST_DEAD:    equ 1
ST_WON:     equ 2

DS_SHUT:    equ 0               ; door states
DS_OPENING: equ 1
DS_OPEN:    equ 2
DS_CLOSING: equ 3
DOOR_GONE:  equ 252             ; a door at this position or more is not drawn

PL_RADIUS:  equ 56              ; 0.22 cell
IN_GO:      equ 0x90            ; IN_FIRE | IN_START

game_run:
        call game_init
gr_1:   call frame
        ld a, (g_state)
        or a
        jr z, gr_1
        ld a, (g_end)
        cp 110
        jr c, gr_1
        call flip_sync
        jp end_screen

game_init:
        ld hl, g_state
        ld de, g_state + 1
        ld bc, ram_end - g_state - 1
        ld (hl), 0
        ldir
        ld hl, START_X
        ld (p_x), hl
        ld hl, START_Z
        ld (p_z), hl
        ld h, START_YAW
        ld l, 0
        ld (p_yawf), hl
        ld hl, EYE
        ld (p_eye), hl
        ld a, 100
        ld (p_hp), a
        ld a, 8
        ld (p_ammo), a
        ld a, 0xFF
        ld (st_cx), a
        ld (last_cx), a
        ld hl, cornermap
        ld de, cornermap + 1
        ld bc, 1023
        ld (hl), a
        ldir
        xor a
        ld (cm_n), a
        ld a, 3
        ld (hud_full), a
        ld a, 96
        ld (gun_x), a
        ; the monsters (spawn_enemies, bank 1): type, cell x, z, direction
        ld hl, spawn_enemies
        ld ix, enemies
        ld b, NENEMY
gi_1:   ld a, (hl)
        inc hl
        ld (ix + EN_TYPE), a
        ld e, a
        ld d, 0
        push hl
        ld hl, et_hp
        add hl, de
        ld a, (hl)
        ld (ix + EN_HP), a
        pop hl
        ld a, (hl)
        inc hl
        ld (ix + EN_X + 1), a
        ld (ix + EN_X), 128
        ld a, (hl)
        inc hl
        ld (ix + EN_Z + 1), a
        ld (ix + EN_Z), 128
        ld e, (hl)
        inc hl
        push hl
        ld hl, face_tab
        add hl, de
        ld a, (hl)
        ld (ix + EN_FACE), a
        ld (ix + EN_DIR), 0xFF
        xor a
        call en_frame
        pop hl
        ld de, EN_SIZE
        add ix, de
        djnz gi_1
        di
        ld hl, (vcount)
        call eiop
        ld (frm_v0), hl
        ret
face_tab:
        db 0, 3, 1, 2               ; the level's east, north, west, south as +x, -z, -x, +z

; ---------------------------------------------------------------- a frame
frame:
        di
        ld hl, (vcount)
        call eiop
        ld de, (frm_v0)
        ld (frm_v0), hl
        or a
        sbc hl, de
        ld a, h
        or a
        jr nz, fm_cap
        ld a, l
        cp 9
        jr c, fm_1
fm_cap: ld a, 8
fm_1:   or a
        jr nz, fm_2
        inc a
fm_2:   ld (dt), a
        ld (st_ticks), a
        call pal_update
        ; the geometry goes to geo3d's RAM while the last frame waits for its
        ; vertical blank (nothing may be drawn yet) and, once that frame is
        ; on show, while the V9968 fills the ceiling and the floor: bg_try,
        ; here and between the faces, starts a fill if it can and never waits
        call cam_setup
        call st_check
        xor a
        ld (bg_n), a
        call bg_try
        call near_emit
        call bg_try
        call dr_emit
        call bg_try
        call mons_emit
        call bg_rest                ; the last frame is on show, the fills started
        call wait_ce
        call geo_run
        call logic                  ; (geo3d and the V9968 draw meanwhile)
        call geo_wait
        call wait_ce
        call ov_draw
        call hud_update
        call flip_ask
        ld hl, (st_frames)
        inc hl
        ld (st_frames), hl
        ret

; the palette the moment asks for: hurt (and dead) red, a pickup's flash
pal_update:
        ld b, 0
        ld a, (pick_t)
        or a
        jr z, pu_b
        ld b, 2
pu_b:   ld a, (hurt_t)
        or a
        jr z, pu_c
        ld b, 1
pu_c:   ld a, (g_state)
        cp ST_DEAD
        jr nz, pu_d
        ld b, 1
pu_d:   ld a, (pal_cur)
        cp b
        ret z
        ld a, b
        jp pal_load

; the monsters and the ammo they left, where the player's cell sees their area
mons_emit:
        ld hl, 0
        ld (bb_hw), hl
        ld a, (p_cx)
        add a, WIN
        ld c, a
        ld hl, enemies + EN_X + 1
        ld de, EN_SIZE
        ld b, NENEMY
me_1:   ld a, c
        sub (hl)
        cp WIN_W
        jr c, me_in                 ; (few: most are far to the east or west)
me_2:   add hl, de
        djnz me_1
        jr me_3
me_in:  push bc
        push hl
        ld de, 0 - (EN_X + 1)
        add hl, de
        push hl
        pop ix
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        call area_seen
        jr z, me_5
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld a, (ix + EN_FRAME)
        call bb_emit
        call bg_try
me_5:   pop hl
        pop bc
        ld de, EN_SIZE
        jr me_2
me_3:   call bg_try
        ld hl, loose
        ld b, 8
me_6:   push bc
        ld b, (hl)
        inc hl
        ld c, (hl)
        inc hl
        push hl
        ld a, b
        or a
        jr z, me_4
        push bc
        call area_seen
        pop bc
        jr z, me_4
        ld d, b
        ld e, 128
        ld h, c
        ld l, 128
        ld a, FR_AMMO
        call bb_emit
me_4:   pop hl
        pop bc
        djnz me_6
        ret

; ---------------------------------------------------------------- logic
logic:
        ; the timers run down
        ld a, (dt)
        ld c, a
        ld hl, fire_cd
        ld b, 5
lg_1:   ld a, (hl)
        sub c
        jr nc, lg_2
        xor a
lg_2:   ld (hl), a
        inc hl
        djnz lg_1
        ld a, (g_state)
        or a
        jr nz, lg_end
        ld a, (dbg_freeze)
        or a
        ret nz
        call player_update
        call doors_update
        call enemies_update
        call pickups
        call gun_update
        ; the elevator's floor ends the level
        ld a, (p_x + 1)
        ld b, a
        ld a, (p_z + 1)
        ld c, a
        call grid_at
        cp AREA_EXIT
        ret nz
        ld a, ST_WON
        ld (g_state), a
        xor a
        ld (g_end), a
        ld a, SFX_BONUS
        jp sfx_play
lg_end: ld a, (dt)
        ld b, a
        ld a, (g_end)
        add a, b
        jr nc, lg_3
        ld a, 255
lg_3:   ld (g_end), a
        ld a, (g_state)
        cp ST_DEAD
        ret nz
        ; dead: the eye sinks, the pistol drops
        ld a, (dt)
        add a, a
        add a, a
        ld b, a
        ld a, (p_eye)
        sub b
        cp 36
        jr nc, lg_4
        ld a, 36
lg_4:   ld (p_eye), a
        ld a, (gun_y)
        add a, b
        cp 76
        jr c, lg_5
        ld a, 76
lg_5:   ld (gun_y), a
        ret

; the pistol's place and frame: it bobs while the player walks, kicks at a
; shot and shows its firing frame for a moment
gun_update:
        ld bc, 0                    ; B = bob x, C = bob y
        ld a, (moving)
        or a
        jr z, gu_1
        ld a, (dt)
        ld e, a
        add a, a
        add a, e                    ; 3 dt: about 0.7 turn a second
        ld hl, bob
        add a, (hl)
        ld (hl), a
        call sin_a
        ld a, h                     ; sin * 64
        call gu_3
        ld b, a
        push bc
        ld a, (bob)
        add a, 64
        call sin_a
        call abs_hl
        ld a, h
        call gu_3
        pop bc
        ld c, a
gu_1:   ld a, b
        add a, 96
        ld (gun_x), a
        ld a, (recoil)
        add a, c
        ld (gun_y), a
        xor a
        ld hl, muzzle_t
        cp (hl)
        jr z, gu_2
        inc a
gu_2:   ld (gun_f), a
        ret
; A (-64..64) -> A * 3 / 64
gu_3:   sra a
        ld e, a
        add a, a
        add a, e
        sra a
        sra a
        sra a
        sra a
        sra a
        ret

; ---------------------------------------------------------------- the player
player_update:
        ld a, (in_cur)
        ld c, a
        ; turn: 417 / 256 of a step per tick (2.4 rad/s)
        ld a, (dt)
        ld b, a
        ld hl, 0
        ld de, 417
py_1:   add hl, de
        djnz py_1
        ex de, hl
        ld hl, (p_yawf)
        bit IN_LEFT, c
        jr z, py_2
        or a
        sbc hl, de
py_2:   bit IN_RIGHT, c
        jr z, py_3
        add hl, de
py_3:   ld (p_yawf), hl
        ; the view vector of the new yaw
        ld a, h
        call sin_a
        ld (mv_fx), hl
        ld a, (p_yaw)
        add a, 64
        call sin_a
        call neg_hl
        ld (mv_fz), hl
        ; walk: 3.2 cells/s = 13.65 units per tick
        xor a
        ld (moving), a
        ld hl, 0
        ld (mv_x), hl
        ld (mv_z), hl
        ld a, (in_cur)
        ld c, a
        ld e, 0                     ; E = forward (1, 0, -1)
        bit IN_UP, c
        jr z, py_4
        inc e
py_4:   bit IN_DOWN, c
        jr z, py_5
        dec e
py_5:   ld d, 0                     ; D = to the right
        bit IN_SR, c
        jr z, py_6
        inc d
py_6:   bit IN_SL, c
        jr z, py_7
        dec d
py_7:   ld a, e
        or d
        jp z, py_door
        ld a, 1
        ld (moving), a
        push de
        ld a, (dt)
        ld b, a
        ld hl, 0
        ld de, 3494
py_8:   add hl, de
        djnz py_8
        pop de
        ld b, h                     ; B = the step
        ld a, e
        or a
        jr z, py_9
        ld a, d
        or a
        jr z, py_9
        ld a, b                     ; both ways: 0.69 of the step each
        srl a
        srl a
        ld l, a
        srl a
        srl a
        add a, l
        ld l, a
        ld a, b
        sub l
        ld b, a
py_9:   ld a, b
        ld (mv_s), a
        ld (mv_fs), de
        ld a, e
        or a
        jr z, py_10
        call py_amt                 ; HL = +- step
        push hl
        ex de, hl
        ld bc, (mv_fx)
        call mulq14
        ld (mv_x), hl
        pop de
        ld bc, (mv_fz)
        call mulq14
        ld (mv_z), hl
py_10:  ld a, (mv_fs + 1)
        or a
        jr z, py_11
        call py_amt
        push hl
        ex de, hl                   ; right = (-fz, fx)
        ld bc, (mv_fz)
        call mulq14
        call neg_hl
        ld de, (mv_x)
        add hl, de
        ld (mv_x), hl
        pop de
        ld bc, (mv_fx)
        call mulq14
        ld de, (mv_z)
        add hl, de
        ld (mv_z), hl
py_11:  ld hl, (p_x)
        ld (tmp), hl
        ld hl, (p_z)
        ld (tmp + 2), hl
        ld a, PL_RADIUS
        ld (bk_r), a
        ld hl, (p_x)
        ld de, (mv_x)
        add hl, de
        ld (bk_x), hl
        ld hl, (p_z)
        ld (bk_z), hl
        call blocked
        jr nz, py_12
        ld hl, (bk_x)
        ld (p_x), hl
py_12:  ld hl, (p_x)
        ld (bk_x), hl
        ld hl, (p_z)
        ld de, (mv_z)
        add hl, de
        ld (bk_z), hl
        call blocked
        jr nz, py_13
        ld hl, (bk_z)
        ld (p_z), hl
py_13:  call enemy_near             ; living monsters are solid
        jr z, py_door
        ld hl, (tmp)
        ld (p_x), hl
        ld hl, (tmp + 2)
        ld (p_z), hl
py_door:
        ; a door in the next cell the player faces opens by itself
        ld a, (p_x + 1)
        ld b, a
        ld a, (p_z + 1)
        ld c, a
        ld a, (p_yaw)
        add a, 32
        rlca
        rlca
        and 3                       ; 0 north, 1 east, 2 south, 3 west
        jr z, pd_n
        dec a
        jr z, pd_e
        dec a
        jr z, pd_s
        dec b
        jr pd_1
pd_n:   dec c
        jr pd_1
pd_e:   inc b
        jr pd_1
pd_s:   inc c
pd_1:   call grid_at
        ld c, a
        and 0xC0
        cp 0x80
        jr nz, py_fire
        ld a, c
        and 63
        call door_open
py_fire:
        ld a, (in_cur)
        bit IN_FIRE, a
        ret z
        ld a, (fire_cd)
        or a
        ret nz
        jp fire

; A = 1 or -1 -> HL = +- mv_s
py_amt: ld b, a
        ld a, (mv_s)
        ld l, a
        ld h, 0
        bit 7, b
        ret z
        jp neg_hl

; bk_x, bk_z, bk_r: NZ if a circle there touches something solid
blocked:
        ld a, (bk_r)
        ld e, a
        ld d, 0
        ld hl, (bk_x)
        or a
        sbc hl, de
        ld a, h
        ld (bk_c), a
        ld hl, (bk_x)
        add hl, de
        ld a, h
        ld (bk_c + 1), a
        ld hl, (bk_z)
        or a
        sbc hl, de
        ld a, h
        ld (bk_c + 2), a
        ld hl, (bk_z)
        add hl, de
        ld a, h
        ld (bk_c + 3), a
        ld a, (bk_c)
        ld b, a
        ld a, (bk_c + 2)
        ld c, a
        call solid_at
        ret nz
        ld a, (bk_c + 1)
        ld b, a
        call solid_at
        ret nz
        ld a, (bk_c + 3)
        ld c, a
        call solid_at
        ret nz
        ld a, (bk_c)
        ld b, a
        jp solid_at

; DE = x, HL = z -> HL = distance to the player (dist_approx)
dist_xz:
        push hl
        ex de, hl
        ld de, (p_x)
        or a
        sbc hl, de
        call abs_hl
        ex (sp), hl
        ld de, (p_z)
        or a
        sbc hl, de
        call abs_hl
        pop de
        jp dist_approx

; NZ if a living monster is closer than 0.45 cell to the player
enemy_near:
        ld ix, enemies
        ld b, NENEMY
en_1:   ld a, (ix + EN_STATE)
        cp ES_DYING
        jr nc, en_2
        ld a, (p_x + 1)             ; two cells away or more: not near
        sub (ix + EN_X + 1)
        inc a
        cp 3
        jr nc, en_2
        ld a, (p_z + 1)
        sub (ix + EN_Z + 1)
        inc a
        cp 3
        jr nc, en_2
        push bc
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        call dist_xz
        pop bc
        ld a, h
        or a
        jr nz, en_2
        ld a, l
        cp 115
        jr c, en_3
en_2:   ld de, EN_SIZE
        add ix, de
        djnz en_1
        xor a
        ret
en_3:   or 1
        ret

; ---------------------------------------------------------------- doors
; A = door: open it (it then stays open about 4 s after the last one through)
door_open:
        ld e, a
        ld d, 0
        ld hl, door_st
        add hl, de
        ld a, (hl)
        cp DS_OPEN
        jr z, do_2
        cp DS_OPENING
        ret z
        ld (hl), DS_OPENING
        or a
        ret nz                      ; it was closing
        ld a, 1
        ld (st_dirty), a            ; what it hid comes into sight
        ld a, SFX_DOOR
        jp sfx_play
do_2:   ld hl, door_tm
        add hl, de
        ld (hl), 240
        ret

; every door moves 4 units of position a tick
doors_update:
        ld c, 0
du_1:   ld b, 0
        ld hl, door_st
        add hl, bc
        ld a, (hl)
        or a
        jp z, du_next
        dec a
        jr z, du_opening
        dec a
        jr z, du_open
        ; closing
        push bc
        call door_busy
        pop bc
        jr nz, du_reopen
        call du_step
        ld hl, door_pos
        add hl, bc
        ld a, (hl)
        sub e
        jr z, du_shut
        jr c, du_shut
        ld (hl), a
        jr du_next
du_shut:
        ld (hl), 0
        ld hl, door_st
        add hl, bc
        ld (hl), DS_SHUT
        ld a, 1
        ld (st_dirty), a
        jr du_next
du_reopen:
        ld hl, door_st
        ld b, 0
        add hl, bc
        ld (hl), DS_OPENING
        jr du_next
du_opening:
        call du_step
        ld hl, door_pos
        add hl, bc
        ld a, (hl)
        add a, e
        jr nc, du_2
        ld a, 255
du_2:   ld (hl), a
        cp 255
        jr nz, du_next
        ld hl, door_st
        add hl, bc
        ld (hl), DS_OPEN
        ld hl, door_tm
        add hl, bc
        ld (hl), 240
        jr du_next
du_open:
        ld hl, door_tm
        add hl, bc
        ld a, (dt)
        ld e, a
        ld a, (hl)
        sub e
        jr c, du_3
        ld (hl), a
        jr nz, du_next
du_3:   push bc
        call door_busy
        pop bc
        ld b, 0
        jr z, du_4
        ld hl, door_tm              ; someone in the doorway: wait a second more
        add hl, bc
        ld (hl), 60
        jr du_next
du_4:   ld hl, door_st
        add hl, bc
        ld (hl), DS_CLOSING
        push bc
        ld a, SFX_DOOR
        call sfx_play
        pop bc
du_next:
        inc c
        ld a, c
        cp NDOOR
        jp nz, du_1
        ret

; E = 4 dt, B = 0
du_step:
        ld a, (dt)
        add a, a
        add a, a
        ld e, a
        ld b, 0
        ret

; C = door -> NZ if the player or a living monster is in its cell or on the
; way into it
door_busy:
        ld l, c
        ld h, 0
        add hl, hl
        add hl, hl
        ld de, door_tab
        add hl, de
        ld d, (hl)                  ; cell x
        inc hl
        ld e, (hl)                  ; cell z
        ld a, (p_x + 1)
        cp d
        jr nz, dby_1
        ld a, (p_z + 1)
        cp e
        jr z, dby_yes
dby_1:   ld ix, enemies
        ld b, NENEMY
dby_2:   ld a, (ix + EN_STATE)
        cp ES_DYING
        jr nc, dby_4
        ld a, (ix + EN_X + 1)
        cp d
        jr nz, dby_3
        ld a, (ix + EN_Z + 1)
        cp e
        jr z, dby_yes
dby_3:   ld a, (ix + EN_TX)
        cp d
        jr nz, dby_4
        ld a, (ix + EN_TZ)
        cp e
        jr z, dby_yes
dby_4:   push de
        ld de, EN_SIZE
        add ix, de
        pop de
        djnz dby_2
        xor a
        ret
dby_yes: or 1
        ret

; ---------------------------------------------------------------- sight
; B = cx, C = cz -> Z if nothing stands between that cell and the player's:
; the cells on the line between them, walls and doors less than half open
los:    ld a, b
        ld (ls_x), a
        ld a, c
        ld (ls_z), a
        ld a, (p_x + 1)
        sub b
        ld d, 1
        jr nc, ls_1
        neg
        ld d, 0xFF
ls_1:   ld (ls_dx), a
        ld a, d
        ld (ls_sx), a
        ld a, (p_z + 1)
        sub c
        ld d, 1
        jr nc, ls_2
        neg
        ld d, 0xFF
ls_2:   ld (ls_dz), a
        ld a, d
        ld (ls_sz), a
        ld a, (ls_dx)
        ld b, a
        ld a, (ls_dz)
        cp b
        jr nc, ls_zm
        ; more cells along x
        ld a, b
        cp 2
        jr c, ls_yes
        dec a
        ld (ls_n), a
        ld a, b
        srl a
        ld (ls_e), a
ls_x1:  ld hl, ls_x
        ld a, (ls_sx)
        add a, (hl)
        ld (hl), a
        ld a, (ls_dz)
        ld c, a
        ld a, (ls_e)
        sub c
        jr nc, ls_x2
        ld hl, ls_dx
        add a, (hl)
        ld c, a
        ld hl, ls_z
        ld a, (ls_sz)
        add a, (hl)
        ld (hl), a
        ld a, c
ls_x2:  ld (ls_e), a
        ld a, (ls_x)
        ld b, a
        ld a, (ls_z)
        ld c, a
        call shot_at
        ret nz
        ld hl, ls_n
        dec (hl)
        jr nz, ls_x1
ls_yes: xor a
        ret
ls_zm:  ; more cells along z (or as many)
        cp 2
        jr c, ls_yes
        ld b, a
        dec a
        ld (ls_n), a
        ld a, b
        srl a
        ld (ls_e), a
ls_z1:  ld hl, ls_z
        ld a, (ls_sz)
        add a, (hl)
        ld (hl), a
        ld a, (ls_dx)
        ld c, a
        ld a, (ls_e)
        sub c
        jr nc, ls_z2
        ld hl, ls_dz
        add a, (hl)
        ld c, a
        ld hl, ls_x
        ld a, (ls_sx)
        add a, (hl)
        ld (hl), a
        ld a, c
ls_z2:  ld (ls_e), a
        ld a, (ls_x)
        ld b, a
        ld a, (ls_z)
        ld c, a
        call shot_at
        ret nz
        ld hl, ls_n
        dec (hl)
        jr nz, ls_z1
        xor a
        ret

; ---------------------------------------------------------------- the shot
; A ray in steps of 32 units to the first wall or shut door, then the
; nearest living monster closer than that and within 0.3 cell of the line
fire:
        ld a, 19
        ld (fire_cd), a
        ld a, (p_ammo)
        or a
        jr nz, fi_0
        ld a, SFX_EMPTY
        jp sfx_play
fi_0:   dec a
        ld (p_ammo), a
        ld a, HF_AMMO
        call hud_mark
        ld a, 6
        ld (muzzle_t), a
        ld (recoil), a
        ld a, SFX_SHOT
        call sfx_play
        ; positions times 2; the step is f * 32 units = (f >> 8) of those
        ld hl, (p_x)
        add hl, hl
        ld (sh_x), hl
        ld hl, (p_z)
        add hl, hl
        ld (sh_z), hl
        ld a, (mv_fx + 1)
        ld l, a
        rlca
        sbc a, a
        ld h, a
        ld (sh_sx), hl
        ld a, (mv_fz + 1)
        ld l, a
        rlca
        sbc a, a
        ld h, a
        ld (sh_sz), hl
        ld hl, 0
        ld (sh_wall), hl
        ld b, 96
fi_1:   push bc
        ld hl, (sh_x)
        ld de, (sh_sx)
        add hl, de
        ld (sh_x), hl
        ld a, h
        srl a
        ld b, a
        ld hl, (sh_z)
        ld de, (sh_sz)
        add hl, de
        ld (sh_z), hl
        ld a, h
        srl a
        ld c, a
        call shot_at
        pop bc
        jr nz, fi_2
        ld hl, (sh_wall)
        ld de, 32
        add hl, de
        ld (sh_wall), hl
        djnz fi_1
fi_2:   ld hl, (sh_wall)
        ld (sh_best), hl
        ld hl, 0
        ld (sh_hit), hl
        ld ix, enemies
        ld b, NENEMY
fi_3:   push bc
        ld a, (ix + EN_STATE)
        cp ES_DYING
        jp nc, fi_5
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        call area_seen
        jp z, fi_5
        ; a standing monster in sight hears the shot
        ld a, (ix + EN_STATE)
        or a
        call z, en_alert
        ; along = v . f
        ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        ld de, (p_x)
        or a
        sbc hl, de
        ld (tmp), hl                ; vx
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        ld de, (p_z)
        or a
        sbc hl, de
        ld (tmp + 2), hl            ; vz
        ld de, (tmp)
        ld bc, (mv_fx)
        call mulq14
        push hl
        ld de, (tmp + 2)
        ld bc, (mv_fz)
        call mulq14
        pop de
        add hl, de
        ld (tmp + 4), hl
        bit 7, h
        jp nz, fi_5                 ; behind
        ld de, 26
        or a
        sbc hl, de
        jp c, fi_5                  ; too close to tell
        ld hl, (tmp + 4)
        ld de, (sh_best)
        or a
        sbc hl, de
        jp nc, fi_5                 ; behind the wall or a nearer monster
        ; across = v x f
        ld de, (tmp)
        ld bc, (mv_fz)
        call mulq14
        push hl
        ld de, (tmp + 2)
        ld bc, (mv_fx)
        call mulq14
        pop de
        ex de, hl
        or a
        sbc hl, de
        call abs_hl
        ld de, 77
        or a
        sbc hl, de
        jp nc, fi_5
        ld hl, (tmp + 4)
        ld (sh_best), hl
        push ix
        pop hl
        ld (sh_hit), hl
fi_5:   ld de, EN_SIZE
        add ix, de
        pop bc
        dec b
        jp nz, fi_3
        ld hl, (sh_hit)
        ld a, h
        or l
        ret z
        push hl
        pop ix
        call rand
        and 31
        add a, 8
        jp hurt_enemy

; ---------------------------------------------------------------- pickups
; cobj: the pickups of the player's cell, found again when the cell changes
pickups:
        ld a, (p_x + 1)
        ld b, a
        ld a, (p_z + 1)
        ld c, a
        ld hl, last_cx
        ld a, b
        cp (hl)
        jr nz, pk_scan
        inc hl
        ld a, c
        cp (hl)
        jr z, pk_have
pk_scan:
        ld hl, last_cx
        ld (hl), b
        inc hl
        ld (hl), c
        xor a
        ld (cobj_n), a
        ld hl, obj_tab
        ld d, 0                     ; the object's number
pk_1:   ld a, (hl)
        cp b
        jr nz, pk_2
        inc hl
        ld a, (hl)
        dec hl
        cp c
        jr nz, pk_2
        inc hl
        inc hl
        inc hl
        ld a, (hl)                  ; kind
        dec hl
        dec hl
        dec hl
        or a
        jr z, pk_2
        ld a, (cobj_n)
        cp 4
        jr nc, pk_2
        push hl
        ld e, a
        inc a
        ld (cobj_n), a
        ld hl, cobj
        ld a, d
        ld d, 0
        add hl, de
        ld (hl), a
        ld d, a
        pop hl
pk_2:   inc hl
        inc hl
        inc hl
        inc hl
        inc d
        ld a, d
        cp NOBJ
        jr nz, pk_1
pk_have:
        ld a, (cobj_n)
        or a
        jr z, pk_loose
        ld b, a
        ld hl, cobj
pk_3:   push bc
        push hl
        ld a, (hl)
        cp 0xFF
        call nz, pk_try
        pop hl
        jr nz, pk_4
        ld (hl), 0xFF               ; taken
pk_4:   inc hl
        pop bc
        djnz pk_3
pk_loose:
        ; ammo a guard left in this cell
        ld a, (p_x + 1)
        ld d, a
        ld a, (p_z + 1)
        ld e, a
        ld hl, loose
        ld b, 8
pk_5:   ld a, (hl)
        cp d
        jr nz, pk_6
        inc hl
        ld a, (hl)
        dec hl
        cp e
        jr nz, pk_6
        ld a, (p_ammo)
        cp 99
        jr nc, pk_6
        ld (hl), 0
        ld a, 4
        call give_ammo
        ret
pk_6:   inc hl
        inc hl
        djnz pk_5
        ret

; A = object: take it if it is of use and not taken yet -> Z if taken (or
; already gone), NZ if left there
pk_try: ld (tmp + 6), a
        call obj_taken
        jp nz, pt_gone
        ld a, (tmp + 6)
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        ld de, obj_tab + 3
        add hl, de
        ld a, (hl)                  ; kind
        cp K_AMMO
        jr z, pt_ammo
        cp K_CROSS
        jr nc, pt_gold
        ; food, dog food, medkit: not for a healthy player
        ld b, a
        ld a, (p_hp)
        cp 100
        jp nc, pt_leave
        ld a, b
        ld c, 10
        cp K_FOOD
        jr z, pt_heal
        ld c, 4
        cp K_DOGFOOD
        jr z, pt_heal
        ld c, 25
pt_heal:
        ld a, (p_hp)
        add a, c
        cp 100
        jr c, pt_h1
        ld a, 100
pt_h1:  ld (p_hp), a
        ld a, HF_HP
        call hud_mark
        ld a, SFX_PICKUP
        jr pt_took
pt_ammo:
        ld a, (p_ammo)
        cp 99
        jr nc, pt_leave
        ld a, 8
        call give_ammo
        jr pt_mark
pt_gold:
        ld c, 1
        jr z, pt_g1                 ; a cross: 100
        ld c, 5
        cp K_CHALICE
        jr z, pt_g1
        cp K_FULL
        jr z, pt_full
        ld c, 10
pt_g1:  ld a, c
        call give_score
        ld a, SFX_BONUS
        jr pt_took
pt_full:
        ld a, 100
        ld (p_hp), a
        ld a, HF_HP
        call hud_mark
        ld a, SFX_BONUS
pt_took:
        call sfx_play
        ld a, 10
        ld (pick_t), a
pt_mark:
        ; the object's bit in `taken`; the billboards are built again
        ld a, (tmp + 6)
        ld c, a
        rrca
        rrca
        rrca
        and 31
        ld e, a
        ld d, 0
        ld hl, taken
        add hl, de
        push hl
        ld a, c
        and 7
        ld e, a
        ld hl, bit_tab
        add hl, de
        ld a, (hl)
        pop hl
        or (hl)
        ld (hl), a
        ld a, 1
        ld (ob_dirty), a
pt_gone:
        xor a
        ret
pt_leave:
        or 1
        ret

; A = bullets to add (99 at most)
give_ammo:
        ld hl, p_ammo
        add a, (hl)
        cp 100
        jr c, ga_1
        ld a, 99
ga_1:   ld (hl), a
        ld a, HF_AMMO
        call hud_mark
        ld a, 10
        ld (pick_t), a
        ld a, SFX_PICKUP
        jp sfx_play

; A = hundreds of points to add
give_score:
        ld hl, p_score
        add a, (hl)
        jr nc, gs_1
        ld a, 255
gs_1:   ld (hl), a
        ld a, HF_SCORE
        jp hud_mark
