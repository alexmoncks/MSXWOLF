; ============================================================================
; hud.asm - text, the status bar, the title and the end screens
;
; Text is written straight into VRAM (1 byte a pixel) from the MSX's own
; 8 x 8 font (CGTABL), each dot 1 or 2 pixels wide and high (txt_scale), in
; txt_fg on txt_bg, on page txt_page. That takes about 0.2 ms a character,
; too slow for the game loop, so the status bar's digits are drawn once
; (hud_prep) in the rows of page 0 that are never shown (212 up) and copied
; from there by the V9968 (HMMM) when a number changes:
;   rows 212..227  "0123456789% " 16 x 16
; Boxes are HMMV fills. Nothing here may run while geo3d is drawing.
; The status bar is rows 180..211 of both pages: hud_full marks the pages
; that still need all of it; hud_dirty has the fields (HF_*) that are old,
; page 0's in the low nibble and page 1's in the high one.
; ============================================================================

HF_HP:      equ 1
HF_SCORE:   equ 2
HF_AMMO:    equ 4

; HL -> text (0 ends), E = x, D = y
txt_put:
        ld (tx_str), hl
        ld (tx_xy), de
        xor a
        ld (tx_row), a
tp_row: ld a, (txt_scale)
        ld b, a
tp_rep: push bc
        ld a, (txt_page)
        ld c, a
        ld hl, (tx_xy)
        call vaddr_w
        ld hl, (tx_str)
tp_ch:  ld a, (hl)
        or a
        jr z, tp_eol
        inc hl
        push hl
        ld l, a
        ld h, 0
        add hl, hl
        add hl, hl
        add hl, hl
        ld de, (txt_font)
        add hl, de
        ld a, (tx_row)
        ld e, a
        ld d, 0
        add hl, de
        ld d, (hl)                  ; the glyph's row
        ld hl, (txt_fg)             ; L = ink, H = paper
        ld b, 8
        ld a, (txt_scale)
        dec a
        jr nz, tp_w
tp_n:   rlc d
        ld a, h
        jr nc, tp_n1
        ld a, l
tp_n1:  out (VDP_DATA), a
        djnz tp_n
        jr tp_cn
tp_w:   rlc d
        ld a, h
        jr nc, tp_w1
        ld a, l
tp_w1:  out (VDP_DATA), a
        out (VDP_DATA), a
        djnz tp_w
tp_cn:  pop hl
        jr tp_ch
tp_eol: pop bc
        ld hl, tx_xy + 1
        inc (hl)
        djnz tp_rep
        ld hl, tx_row
        inc (hl)
        ld a, (hl)
        cp 8
        jr nz, tp_row
        ret

; HL -> db x, y, colour, scale, text, 0 -> HL after it
txt_at: ld e, (hl)
        inc hl
        ld d, (hl)
        inc hl
        ld a, (hl)
        inc hl
        ld (txt_fg), a
        ld a, (hl)
        inc hl
        ld (txt_scale), a
        push hl
        call txt_put
        pop hl
ta_1:   ld a, (hl)
        inc hl
        or a
        jr nz, ta_1
        ret

; HL -> B texts for txt_at
txt_list:
        push bc
        call txt_at
        pop bc
        djnz txt_list
        ret

; HL -> db x, y, dw width, db height, colour: a filled box on txt_page
; -> HL after it
box:    ld a, (hl)
        inc hl
        ld (cmd_dx), a
        xor a
        ld (cmd_dx + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_dy), a
        ld a, (txt_page)
        ld (cmd_dy + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_nx), a
        ld a, (hl)
        inc hl
        ld (cmd_nx + 1), a
        ld a, (hl)
        inc hl
        ld (cmd_ny), a
        xor a
        ld (cmd_ny + 1), a
        ld a, (hl)
        inc hl
        push hl
        call fill
        pop hl
        ret

; HL -> B boxes
box_list:
        push bc
        call box
        pop bc
        djnz box_list
        ret

; A -> numbuf: 3 characters, leading zeros as spaces, then 0
num3:   ld hl, numbuf
        ld c, 0
        ld b, 100
        call nm_dig
        ld b, 10
        call nm_dig
        add a, '0'
        ld (hl), a
        inc hl
        ld (hl), 0
        ret
nm_dig: ld d, '0' - 1
nm_1:   inc d
        sub b
        jr nc, nm_1
        add a, b
        ld e, a
        ld a, d
        cp '0'
        jr nz, nm_2
        ld a, c
        or a
        ld a, ' '
        jr z, nm_3
        ld a, '0'
        jr nm_3
nm_2:   ld c, 1
nm_3:   ld (hl), a
        inc hl
        ld a, e
        ret

; ---------------------------------------------------------------- status bar
; the digits, once, in the hidden rows of page 0
hud_prep:
        xor a
        ld (txt_page), a
        ld a, 1
        ld (txt_bg), a
        ld hl, prep_texts
        ld b, 1
        jp txt_list
prep_texts:
        db 0, 212, 3, 2
        db "0123456789% ", 0

; A = fields (HF_*): they are old on both pages
hud_mark:
        ld b, a
        rlca
        rlca
        rlca
        rlca
        or b
        ld hl, hud_dirty
        or (hl)
        ld (hl), a
        ret

hud_update:
        ld a, (buf)
        ld (txt_page), a
        or a
        jr nz, hu_p1
        ld a, (hud_dirty)
        ld c, a
        and 0xF0
        ld (hud_dirty), a
        ld b, 1
        jr hu_2
hu_p1:  ld a, (hud_dirty)
        ld c, a
        and 0x0F
        ld (hud_dirty), a
        ld a, c
        rrca
        rrca
        rrca
        rrca
        ld c, a
        ld b, 2
hu_2:   ; C = this page's old fields, B = its bit in hud_full
        ld a, (hud_full)
        and b
        jr z, hu_3
        ld a, (hud_full)
        xor b
        ld (hud_full), a
        jr hud_bar
hu_3:   ld a, c
        and 7
        ret z
        jr hud_fields

; the whole bar on txt_page
hud_bar:
        ld hl, bar_boxes
        ld b, 5
        call box_list
        ld a, 1
        ld (txt_bg), a
        ld hl, bar_texts
        ld b, 3
        call txt_list
        ld a, 7
        ; fall through

; A = the fields to draw (HF_*)
hud_fields:
        ld (hud_f), a
        ld hl, 16
        ld (cmd_nx), hl
        ld (cmd_ny), hl
        ld a, (hud_f)
        and HF_SCORE
        jr z, hf_1
        ; points: three digits and "00"
        ld a, (p_score)
        call num3
        ld a, (numbuf)
        ld e, 2
        call big_glyph
        ld a, (numbuf + 1)
        ld e, 18
        call big_glyph
        ld a, (numbuf + 2)
        ld e, 34
        call big_glyph
        ld a, '0'
        ld e, 50
        call big_glyph
        ld a, '0'
        ld e, 66
        call big_glyph
hf_1:   ld a, (hud_f)
        and HF_HP
        jr z, hf_2
        ; health: three digits and the "%"
        ld a, (p_hp)
        call num3
        ld a, (numbuf)
        ld e, 96
        call big_glyph
        ld a, (numbuf + 1)
        ld e, 112
        call big_glyph
        ld a, (numbuf + 2)
        ld e, 128
        call big_glyph
        ld a, '0' + 10
        ld e, 144
        call big_glyph
hf_2:   ld a, (hud_f)
        and HF_AMMO
        ret z
        ld a, (p_ammo)
        call num3
        ld a, (numbuf + 1)
        ld e, 198
        call big_glyph
        ld a, (numbuf + 2)
        ld e, 214
        ; fall through

; A = a digit, '0' + 10 for "%" or a space; E = x: the 16 x 16 glyph at
; (E, 192) of txt_page
big_glyph:
        cp ' '
        jr nz, bg_g1
        ld a, '0' + 11
bg_g1:  sub '0'
        add a, a
        add a, a
        add a, a
        add a, a
        ld b, a
        ld c, 212
        ld d, 192
        ; fall through

; copy cmd_nx x cmd_ny pixels from (B, C) of page 0 to (E, D) of txt_page
hud_cp: ld a, b
        ld (cmd_sx), a
        ld a, c
        ld (cmd_sy), a
        xor a
        ld (cmd_sx + 1), a
        ld (cmd_sy + 1), a
        ld (cmd_dx + 1), a
        ld (cmd_clr), a
        ld (cmd_arg), a
        ld a, e
        ld (cmd_dx), a
        ld a, d
        ld (cmd_dy), a
        ld a, (txt_page)
        ld (cmd_dy + 1), a
        ld a, HMMM
        ld (cmd_op), a
        jp cmd_all

bar_boxes:
        db 0, 180
        dw 256
        db 32, 1                    ; the panel
        db 0, 180
        dw 256
        db 1, 7                     ; its top edge
        db 0, 211
        dw 256
        db 1, 6
        db 86, 181
        dw 1
        db 30, 7                    ; separators
        db 170, 181
        dw 1
        db 30, 7
bar_texts:
        db 18, 183, 2, 1
        db "PONTOS", 0
        db 112, 183, 2, 1
        db "VIDA", 0
        db 186, 183, 2, 1
        db "MUNICAO", 0

; ---------------------------------------------------------------- screens
; the title on the hidden page, shown; waits for the trigger
title_screen:
        xor a
        call pal_load
        ld a, (buf)
        ld (txt_page), a
        ld hl, title_boxes
        ld b, 1
        call box_list
        ld a, 6
        ld (txt_bg), a
        ld hl, title_texts
        ld b, 7
        call txt_list
        call flip
        ; fall through

; wait for the trigger (or RETURN) to be released, then pressed
wait_fire:
        ld a, (in_cur)
        and IN_GO
        jr nz, wait_fire
wf_1:   ld a, (in_cur)
        and IN_GO
        jr z, wf_1
        ret

title_boxes:
        db 0, 0
        dw 256
        db 212, 6
title_texts:
        db 64, 24, 4, 2
        db "MSX WOLF", 0
        db 76, 50, 5, 1
        db "V9968 + GEO3D", 0
        db 16, 92, 2, 1
        db "CURSORES  ANDAR E GIRAR", 0
        db 16, 106, 2, 1
        db "Z  X      PASSO LATERAL", 0
        db 16, 120, 2, 1
        db "ESPACO    ATIRAR", 0
        db 16, 134, 2, 1
        db "AS PORTAS ABREM SOZINHAS", 0
        db 64, 176, 3, 1
        db "PRESSIONE ESPACO", 0

; the end: a box over the picture on show, then the trigger
end_screen:
        call wait_ce
        ld a, (buf)
        xor 1
        ld (txt_page), a
        ld hl, end_boxes
        ld b, 2
        call box_list
        ld a, 1
        ld (txt_bg), a
        ld hl, end_dead
        ld a, (g_state)
        cp 1
        jr z, eds_1
        ld hl, end_won
eds_1:  call txt_at
        ld hl, end_again
        call txt_at
        call wait_ce
        jp wait_fire

end_boxes:
        db 14, 58
        dw 228
        db 64, 7
        db 16, 60
        dw 224
        db 60, 1
end_dead:
        db 40, 70, 4, 2
        db "VOCE MORREU", 0
end_won:
        db 24, 70, 5, 2
        db "FASE COMPLETA", 0
end_again:
        db 68, 100, 2, 1
        db "ESPACO: DE NOVO", 0
