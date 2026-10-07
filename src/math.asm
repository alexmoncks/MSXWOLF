; ============================================================================
; math.asm - fixed point helpers (tools/sim.py has the same functions)
; ============================================================================

; HL = (DE * BC) >> 14, signed: the product of the magnitudes, the sign put
; back after (so it rounds toward zero). Keeps IX, IY.
mulq14:
        ld a, d
        xor b
        push af                     ; bit 7: the result is negative
        bit 7, d
        jr z, mq_1
        xor a
        sub e
        ld e, a
        sbc a, a
        sub d
        ld d, a
mq_1:   bit 7, b
        jr z, mq_2
        xor a
        sub c
        ld c, a
        sbc a, a
        sub b
        ld b, a
mq_2:   ; the product >> 8 = D * BC + (E * BC >> 8): two multiplies of 8 by
        ; 16 bits, and only one when D = 0 (a small factor goes in DE)
        ld a, e
        call mul8
        ld l, h
        ld h, a                     ; HL = E * BC >> 8
        ld a, d
        or a
        jr z, mq_3
        push hl
        call mul8
        pop de
        add hl, de
        adc a, 0
mq_3:   add hl, hl
        rla
        add hl, hl
        rla
        ld l, h
        ld h, a                     ; product >> 14
        pop af
        ret p
; HL = -HL
neg_hl: xor a
        sub l
        ld l, a
        sbc a, a
        sub h
        ld h, a
        ret

; A:HL = A * BC, unsigned (keeps BC, DE). A gives its bits from the top and
; takes what overflows HL at the bottom.
mul8:   ld hl, 0
        add hl, hl
        rla
        jr nc, m8_1
        add hl, bc
        adc a, 0
m8_1:
        add hl, hl
        rla
        jr nc, m8_2
        add hl, bc
        adc a, 0
m8_2:
        add hl, hl
        rla
        jr nc, m8_3
        add hl, bc
        adc a, 0
m8_3:
        add hl, hl
        rla
        jr nc, m8_4
        add hl, bc
        adc a, 0
m8_4:
        add hl, hl
        rla
        jr nc, m8_5
        add hl, bc
        adc a, 0
m8_5:
        add hl, hl
        rla
        jr nc, m8_6
        add hl, bc
        adc a, 0
m8_6:
        add hl, hl
        rla
        jr nc, m8_7
        add hl, bc
        adc a, 0
m8_7:
        add hl, hl
        rla
        jr nc, m8_8
        add hl, bc
        adc a, 0
m8_8:
        ret

; A = floor(256 * HL / DE) for 0 <= HL < DE < 16384
frac8:
        ld b, 8
fr_1:   add hl, hl
        or a
        sbc hl, de
        jr nc, fr_2
        add hl, de                  ; (sets carry)
fr_2:   ccf
        rl c
        djnz fr_1
        ld a, c
        ret

; HL = |HL|
abs_hl: bit 7, h
        ret z
        jr neg_hl

; A = angle (1/256 turn) -> HL = sin in Q2.14
sin_a:  ld l, a
        ld h, 0
        add hl, hl
        ld de, sin_tab
        add hl, de
        ld a, (hl)
        inc hl
        ld h, (hl)
        ld l, a
        ret

; HL = |dx|, DE = |dz| -> HL = distance, about (max + 3/8 min)
dist_approx:
        or a
        sbc hl, de
        add hl, de
        jr nc, da_1                 ; HL >= DE
        ex de, hl
da_1:   srl d
        rr e                        ; min / 2
        add hl, de
        srl d
        rr e
        srl d
        rr e                        ; min / 8
        or a
        sbc hl, de
        ret

; A = an 8-bit pseudo random number
rand:   push hl
        ld hl, (rnd)
        ld a, h
        rrca
        rrca
        rrca
        xor l
        ld h, l
        ld l, a
        ld a, r
        add a, l
        ld l, a
        ld (rnd), hl
        pop hl
        ret
