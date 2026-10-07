; ============================================================================
; enemy.asm - guards and dogs
;
; They work the way Wolfenstein 3D's actors do (WL_STATE.C, studied in
; MSXDOOM/msx/docs/wolf3d-engenharia-reversa.md), which is what makes twenty
; of them cheap:
; - A standing one does nothing but look for the player, and only one of
;   them looks in each frame (ai_rr): its area must be in sight of the
;   player's cell, the player in front of it or next to it, and no wall or
;   shut door on the line between the two cells (los).
; - A chasing one walks from the middle of a cell to the middle of the next,
;   and thinks only when it gets there: shoot (a guard with the player in
;   sight) or bite (a dog next to him), or pick the next cell: toward the
;   player along the longer axis, then the shorter, then straight on, then
;   any way but back, then back. A cell is free if it is floor, no other
;   monster is in it or going to it, and it is not the player's. A shut
;   door is opened and waited for.
; ============================================================================

ES_STAND:   equ 0
ES_CHASE:   equ 1
ES_ATTACK:  equ 2
ES_PAIN:    equ 3
ES_DYING:   equ 4
ES_DEAD:    equ 5

F_STAND:    equ 0               ; frames of a type (fr_tab)
F_WALK1:    equ 1
F_WALK2:    equ 2
F_AIM:      equ 3
F_FIRE:     equ 4
F_PAIN:     equ 5
F_DYING:    equ 6
F_DEAD:     equ 7

; per type (0 guard, 1 dog)
et_hp:      db 25, 1
et_anim:    db 10, 6                ; ticks per walk frame
et_score:   db 1, 2                 ; hundreds of points
et_speed:   dw 1792, 3500           ; units per tick * 256 (1.6 and 3.2 cells/s)
fr_tab:     db FR_GUARD_STAND, FR_GUARD_WALK1, FR_GUARD_WALK2, FR_GUARD_AIM
            db FR_GUARD_FIRE, FR_GUARD_PAIN, FR_GUARD_DYING, FR_GUARD_DEAD
            db FR_DOG_RUN1, FR_DOG_RUN1, FR_DOG_RUN2, FR_DOG_BITE
            db FR_DOG_BITE, FR_DOG_RUN2, FR_DOG_DEAD, FR_DOG_DEAD

enemies_update:
        ld a, (ai_rr)
        inc a
        cp NENEMY
        jr c, eu_0
        xor a
eu_0:   ld (ai_rr), a
        xor a
        ld (ai_i), a
        ld ix, enemies
        ld b, NENEMY
eu_1:   push bc
        call enemy_tick
        ld de, EN_SIZE
        add ix, de
        ld hl, ai_i
        inc (hl)
        pop bc
        djnz eu_1
        ret

; A = frame of the type (F_*) (keeps BC)
en_frame:
        ld e, a
        ld a, (ix + EN_TYPE)
        add a, a
        add a, a
        add a, a
        add a, e
        ld e, a
        ld d, 0
        ld hl, fr_tab
        add hl, de
        ld a, (hl)
        ld (ix + EN_FRAME), a
        ret

; HL -> a byte table per type -> A = the monster's entry
en_byte:
        ld e, (ix + EN_TYPE)
        ld d, 0
        add hl, de
        ld a, (hl)
        ret

; the cells from the monster to the player -> en_dx, en_dz (signed), en_d
; (the larger, unsigned); B, C = the monster's cell
en_cells:
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        ld a, (p_x + 1)
        sub b
        ld (en_dx), a
        jp p, ecl_1
        neg
ecl_1:  ld d, a
        ld a, (p_z + 1)
        sub c
        ld (en_dz), a
        jp p, ecl_2
        neg
ecl_2:  cp d
        jr nc, ecl_3
        ld a, d
ecl_3:  ld (en_d), a
        ret

; A = damage
hurt_enemy:
        ld b, a
        ld a, (ix + EN_HP)
        sub b
        jr c, he_dead
        jr z, he_dead
        ld (ix + EN_HP), a
        ld (ix + EN_STATE), ES_PAIN
        ld (ix + EN_T), 0
        ld a, SFX_PAIN
        jp sfx_play
he_dead:
        ld (ix + EN_HP), 0
        ld (ix + EN_STATE), ES_DYING
        ld (ix + EN_T), 0
        ld hl, kills
        inc (hl)
        ld hl, et_score
        call en_byte
        call give_score
        ld a, SFX_DEATH
        jp sfx_play

; A = damage
hurt_player:
        ld b, a
        ld a, (g_state)
        or a
        ret nz
        ld a, (p_hp)
        sub b
        jr nc, hpl_1
        xor a
hpl_1:  ld (p_hp), a
        ld a, 20
        ld (hurt_t), a
        ld a, HF_HP
        call hud_mark
        ld a, SFX_HURT
        call sfx_play
        ld a, (p_hp)
        or a
        ret nz
        ld a, ST_DEAD
        ld (g_state), a
        xor a
        ld (g_end), a
        ret

; ---------------------------------------------------------------- one monster
enemy_tick:
        ld a, (ix + EN_STATE)
        cp ES_DEAD
        ret z
        or a
        jr z, es_stand
        ld a, (dt)
        add a, (ix + EN_T)
        jr nc, et_1
        ld a, 255
et_1:   ld (ix + EN_T), a
        ld a, (ix + EN_STATE)
        dec a
        jp z, es_chase
        dec a
        jp z, es_attack
        dec a
        jr z, es_pain
        ; dying
        ld a, F_DYING
        call en_frame
        ld a, (ix + EN_T)
        cp 14
        ret c
        ld (ix + EN_STATE), ES_DEAD
        ld a, F_DEAD
        call en_frame
        ; a guard leaves its ammo
        ld a, (ix + EN_TYPE)
        or a
        ret nz
        ld hl, loose
        ld b, 8
ed_1:   ld a, (hl)
        or a
        jr z, ed_2
        inc hl
        inc hl
        djnz ed_1
        ret
ed_2:   ld a, (ix + EN_X + 1)
        ld (hl), a
        inc hl
        ld a, (ix + EN_Z + 1)
        ld (hl), a
        ret

es_pain:
        ld a, F_PAIN
        call en_frame
        ld a, (ix + EN_T)
        cp 10
        ret c
es_to_chase:
        ld (ix + EN_STATE), ES_CHASE
        ld (ix + EN_T), 0
        ret

; standing: this one's turn to look for the player?
es_stand:
        ld a, (ai_i)
        ld hl, ai_rr
        cp (hl)
        ret nz
        call en_cells
        call area_seen
        ret z
        ld a, (en_d)
        cp 13
        ret nc
        cp 2
        jr c, es_look               ; next to it: it notices
        ld a, (ix + EN_FACE)
        or a
        jr z, ef_px
        dec a
        jr z, ef_mx
        dec a
        jr z, ef_pz
        ld a, (en_dz)
        jr ef_neg
ef_px:  ld a, (en_dx)
        jr ef_pos
ef_mx:  ld a, (en_dx)
        jr ef_neg
ef_pz:  ld a, (en_dz)
ef_pos: dec a
        rlca
        ret c                       ; not in front
        jr es_look
ef_neg: rlca
        ret nc
es_look:
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        call los
        ret nz
        ; fall through

; a standing monster starts the chase, with a shout or a bark (keeps BC, IX)
en_alert:
        ld a, (ix + EN_STATE)
        or a
        ret nz
        ld (ix + EN_STATE), ES_CHASE
        ld (ix + EN_T), 0
        ld (ix + EN_REM), 0
        ld (ix + EN_DIR), 0xFF
        ld a, (ix + EN_TYPE)
        add a, SFX_ALERT
        jp sfx_play

; chasing
es_chase:
        ld a, (ix + EN_REM)
        or a
        jp z, ec_think
        ; on to the middle of the next cell
        call en_stepsz
        ld e, a
        ld a, (ix + EN_REM)
        sub e
        jr c, ec_arrive
        jr z, ec_arrive
        ld (ix + EN_REM), a
        ld d, 0
        ld a, (ix + EN_DIR)
        or a
        jr z, ec_px
        dec a
        jr z, ec_mx
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        dec a
        jr z, ec_pz
        or a
        sbc hl, de
        jr ec_z
ec_pz:  add hl, de
ec_z:   ld (ix + EN_Z), l
        ld (ix + EN_Z + 1), h
        jr ec_anim
ec_px:  ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        add hl, de
        jr ec_x
ec_mx:  ld l, (ix + EN_X)
        ld h, (ix + EN_X + 1)
        or a
        sbc hl, de
ec_x:   ld (ix + EN_X), l
        ld (ix + EN_X + 1), h
        jr ec_anim
ec_arrive:
        ld a, (ix + EN_TX)
        ld (ix + EN_X + 1), a
        ld (ix + EN_X), 128
        ld a, (ix + EN_TZ)
        ld (ix + EN_Z + 1), a
        ld (ix + EN_Z), 128
        ld (ix + EN_REM), 0
ec_anim:
        ld hl, et_anim
        call en_byte
        ld b, a
        ld a, (dt)
        add a, (ix + EN_ANIM)
        cp b
        jr c, ec_a1
        sub b
        ld c, a
        ld a, (ix + EN_FLAGS)
        xor 2
        ld (ix + EN_FLAGS), a
        ld a, c
ec_a1:  ld (ix + EN_ANIM), a
        ld a, F_WALK1
        bit 1, (ix + EN_FLAGS)
        jr z, ec_a2
        inc a
ec_a2:  jp en_frame

; in the middle of a cell: attack, or pick the next one
ec_think:
        call en_cells
        ld a, (en_d)
        cp 2
        jr c, ec_attack             ; next to the player
        ld a, (ix + EN_TYPE)
        or a
        jr nz, ec_walk              ; a dog only bites
        ld a, (en_d)
        cp 10
        jr nc, ec_walk
        call rand
        cp 90
        jr nc, ec_walk
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        call los
        jr nz, ec_walk
ec_attack:
        ld (ix + EN_STATE), ES_ATTACK
        ld (ix + EN_T), 0
        res 0, (ix + EN_FLAGS)
        ld a, F_AIM
        jp en_frame
ec_walk:
        call en_cells
        jp sel_dir

; A = units this monster moves in this frame (at least 1)
en_stepsz:
        ld a, (ix + EN_TYPE)
        add a, a
        ld e, a
        ld d, 0
        ld hl, et_speed
        add hl, de
        ld e, (hl)
        inc hl
        ld d, (hl)
        ld a, (dt)
        ld b, a
        ld hl, 0
ez_1:   add hl, de
        djnz ez_1
        ld a, h
        or a
        ret nz
        inc a
        ret

; attacking
es_attack:
        ld a, (ix + EN_TYPE)
        or a
        jr nz, ea_dog
        ; a guard aims, fires 16 ticks in, and takes 48 in all (as slow as
        ; the original's: the player has time to shoot first)
        ld a, (ix + EN_T)
        cp 16
        ld a, F_AIM
        jr c, ea_f
        ld a, (ix + EN_T)
        cp 28
        ld a, F_FIRE
        jr c, ea_f
        ld a, F_AIM
ea_f:   call en_frame
        ld a, (ix + EN_T)
        cp 16
        ret c
        bit 0, (ix + EN_FLAGS)
        jr nz, ea_end
        set 0, (ix + EN_FLAGS)
        ld a, SFX_ESHOT
        call sfx_play
        call en_cells
        call los
        jr nz, ea_end               ; the player got behind something
        ; it hits 256 - 16 d times in 256 (d: cells away)
        ld a, (en_d)
        cp 16
        jr nc, ea_end
        add a, a
        add a, a
        add a, a
        add a, a
        ld b, a
        call rand
        cp b
        jr c, ea_end
        call rand
        rrca
        rrca
        rrca
        and 31                      ; 1..32 from next to him, half from farther
        ld b, a
        ld a, (en_d)
        cp 2
        ld a, b
        jr c, ea_1
        srl a
ea_1:   inc a
        call hurt_player
ea_end: ld a, (ix + EN_T)
        cp 48
        ret c
        jr es_to_chase2
; a dog bites 12 ticks in, if the player is still within reach (1.6 cells),
; 7 times in 10, and takes 40 ticks in all
ea_dog: ld a, F_AIM
        call en_frame
        bit 0, (ix + EN_FLAGS)
        jr nz, ea_d2
        ld a, (ix + EN_T)
        cp 12
        ret c
        set 0, (ix + EN_FLAGS)
        ld a, SFX_BARK
        call sfx_play
        ld e, (ix + EN_X)
        ld d, (ix + EN_X + 1)
        ld l, (ix + EN_Z)
        ld h, (ix + EN_Z + 1)
        call dist_xz
        ld de, 420                  ; next to him, corners too
        or a
        sbc hl, de
        jr nc, ea_d2
        call rand
        cp 180
        jr nc, ea_d2
        call rand
        and 15
        inc a
        call hurt_player
ea_d2:  ld a, (ix + EN_T)
        cp 40
        ret c
es_to_chase2:
        ld (ix + EN_STATE), ES_CHASE
        ld (ix + EN_T), 0
        ret

; ---------------------------------------------------------------- the way
; en_dx, en_dz set: pick the next cell (EN_DIR, EN_TX, EN_TZ, EN_REM)
sel_dir:
        ld a, (en_dx)
        ld b, 0xFF
        or a
        jr z, sl_1
        ld b, 0
        jp p, sl_1
        ld b, 1
sl_1:   ld a, (en_dz)
        ld c, 0xFF
        or a
        jr z, sl_2
        ld c, 2
        jp p, sl_2
        ld c, 3
sl_2:   ld a, (en_dx)
        call abs_a
        ld d, a
        ld a, (en_dz)
        call abs_a
        cp d
        jr c, sl_3
        jr z, sl_3
        ld a, b                     ; farther along z: that way first
        ld b, c
        ld c, a
sl_3:   ld a, b
        ld (en_try), a
        ld a, c
        ld (en_try + 1), a
        ld a, (ix + EN_DIR)
        cp 0xFF
        jr z, sl_4
        xor 1
sl_4:   ld (en_try + 2), a          ; the way back (FFh: none)
        ld a, (en_try)
        call sd_try
        ret z
        ld a, (en_try + 1)
        call sd_try
        ret z
        ld a, (ix + EN_DIR)
        call sd_try
        ret z
        call rand
        and 3
        ld (en_try + 3), a
        ld b, 4
sl_5:   push bc
        ld a, (en_try + 3)
        inc a
        and 3
        ld (en_try + 3), a
        call sd_try
        pop bc
        ret z
        djnz sl_5
        ld a, (en_try + 2)
        cp 0xFF
        jr z, sl_6
        call try_walk
        ret z
sl_6:   ld (ix + EN_DIR), 0xFF
        ret

; A = direction: go that way unless it is none or the way back -> Z if it goes
sd_try: cp 0xFF
        jr z, sd_no
        ld hl, en_try + 2
        cp (hl)
        jp nz, try_walk
sd_no:  or 1
        ret

abs_a:  or a
        ret p
        neg
        ret

; A = direction -> Z if the monster can go to the next cell that way (and
; it is set going), or is waiting there for a door it has just opened
try_walk:
        ld (tmp + 7), a
        ld b, (ix + EN_X + 1)
        ld c, (ix + EN_Z + 1)
        or a
        jr z, tw_px
        dec a
        jr z, tw_mx
        dec a
        jr z, tw_pz
        dec c
        jr tw_1
tw_px:  inc b
        jr tw_1
tw_mx:  dec b
        jr tw_1
tw_pz:  inc c
tw_1:   call grid_at
        ld e, a
        and 0xC0
        jr z, tw_free
        cp 0x80
        jp nz, tw_no                ; a wall or an object
        ld a, e
        and 63
        ld e, a
        ld d, 0
        ld hl, door_st
        add hl, de
        ld a, (hl)
        cp DS_OPEN
        jr z, tw_free
        ld a, e
        push bc
        call door_open
        pop bc
        ld a, (tmp + 7)
        ld (ix + EN_DIR), a
        xor a
        ret
tw_free:
        ld a, (p_x + 1)             ; not into the player's cell
        cp b
        jr nz, tw_2
        ld a, (p_z + 1)
        cp c
        jr z, tw_no
tw_2:   push ix                     ; nor where another monster is or goes
        pop hl
        ld (tmp + 4), hl
        ld iy, enemies
        ld d, NENEMY
tw_3:   push iy
        pop hl
        ld a, (tmp + 4)
        cp l
        jr nz, tw_4
        ld a, (tmp + 5)
        cp h
        jr z, tw_5                  ; itself
tw_4:   ld a, (iy + EN_STATE)
        cp ES_DYING
        jr nc, tw_5
        ld a, (iy + EN_X + 1)
        cp b
        jr nz, tw_6
        ld a, (iy + EN_Z + 1)
        cp c
        jr z, tw_no
tw_6:   ld a, (iy + EN_REM)
        or a
        jr z, tw_5
        ld a, (iy + EN_TX)
        cp b
        jr nz, tw_5
        ld a, (iy + EN_TZ)
        cp c
        jr z, tw_no
tw_5:   push de
        ld de, EN_SIZE
        add iy, de
        pop de
        dec d
        jr nz, tw_3
        ld a, (tmp + 7)
        ld (ix + EN_DIR), a
        ld (ix + EN_TX), b
        ld (ix + EN_TZ), c
        ld (ix + EN_REM), 255
        xor a
        ret
tw_no:  or 1
        ret
