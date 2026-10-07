; ============================================================================
; ram.asm - the RAM map (C000h up; the init clears C000h-E7FFh)
; ============================================================================
        org 0xC000
ram_start:
eiop:       ds 2            ; EI, RET (NOP, RET during init)
vcount:     ds 2            ; vertical blanks (interrupt handler)
flip_req:   ds 1            ; 1: show flip_r2 at the next blank
flip_r2:    ds 1
flip_pend:  ds 1            ; 1: a page was asked for and buf not swapped yet
in_cur:     ds 1            ; IN_* bits
dbg_in:     ds 1            ; tests: keys held from outside
dbg_freeze: ds 1            ; tests: 1 = no input, no monsters, no doors
buf:        ds 1            ; the hidden page, being drawn (0, 1)
bg_n:       ds 1            ; background fills started in this frame
pal_cur:    ds 1
st_geo:     ds 1            ; 0: geo3d did not answer in time
rnd:        ds 2
sv_ptr:     ds 4            ; the two sound voices
psg_mix:    ds 1
txt_font:   ds 2
txt_page:   ds 1
txt_fg:     ds 1
txt_bg:     ds 1
txt_scale:  ds 1
tx_str:     ds 2
tx_xy:      ds 2            ; x, y
tx_row:     ds 1
hud_f:      ds 1
hud_w:      ds 1
zgrid:      ds 32           ; Z * 32 of the 4 x 4 corners around the player (in one page: near_emit)

; ---- VDP command buffer: R#32..R#46
cmdbuf:
cmd_sx:     ds 2
cmd_sy:     ds 2
cmd_dx:     ds 2
cmd_dy:     ds 2
cmd_nx:     ds 2
cmd_ny:     ds 2
cmd_clr:    ds 1
cmd_arg:    ds 1
cmd_op:     ds 1

; ---- the player and the camera
p_x:        ds 2            ; 256 units a cell
p_z:        ds 2
p_yawf:     ds 1            ; fraction of p_yaw
p_yaw:      ds 1            ; 1/256 turn: 0 north (-z), 64 east (+x)
p_eye:      ds 2
p_cx:       ds 1
p_cz:       ds 1
cam_fx:     ds 2            ; forward and right vectors, Q2.14
cam_fz:     ds 2
cam_rx:     ds 2
cam_rz:     ds 2
cambuf:     ds 24           ; geo3d index 00h: M00..M22, TX, TY, TZ

; ---- what geo3d holds
st_cx:      ds 1            ; the cell the static parts were built for (FFh: none)
st_cz:      ds 1
st_yaw:     ds 1            ; the yaw the far faces were filtered for
ob_yaw:     ds 1            ; the yaw the objects are turned to
st_dirty:   ds 1            ; a door started to open or shut: the far faces are old
ob_dirty:   ds 1            ; an object was taken
st_nv:      ds 1            ; vertices and faces: near strips, then far faces ..
st_nf:      ds 1
near_nv:    ds 1            ; .. the near strips' share ..
near_nf:    ds 1
ob_nv:      ds 1            ; .. and with the objects after them
ob_nf:      ds 1
dn_v:       ds 1            ; the frame's totals
dn_f:       ds 1
st_bank:    ds 1            ; the cell's list: its bank, its far part
st_farp:    ds 2
near_n:     ds 1            ; the cell's near walls (2 bytes each)
nearbuf:    ds 64
areas:      ds 5            ; the areas in sight of the cell, a bit each
spr_n:      ds 1            ; the objects in sight (4 bytes each)
sprbuf:     ds 240
door_n:     ds 1            ; the doors in sight (4 bytes each)
doorbuf:    ds 64
ncorner:    ds 16           ; corner around the cell (i + 4 j) -> its top vertex
nwall:      ds 160          ; per near wall: the top vertices at 0, 64, 128, 192, 256
nw_ptr:     ds 2
cornermap:  ds 1024         ; corner (x & 31, z & 31) -> its top vertex (FFh: none yet)
cm_n:       ds 1            ; entries of cornermap in use
cm_list:    ds 2 * 80       ; their addresses
nearab:     ds 64           ; per near wall: its corners' depths in zgrid (low address bytes)
nab_ptr:    ds 2
ne_ia:      ds 1
tmp:        ds 8
ne_row:     ds 2
ne_sx:      ds 2
ne_sz:      ds 2
ne_za:      ds 2
ne_zb:      ds 2
ne_dir:     ds 1
ne_o:       ds 2
ne_e:       ds 2
ne_ax:      ds 2
ne_az:      ds 2
ne_vx:      ds 2
ne_vz:      ds 2
ne_u:       ds 1
fc_a:       ds 1            ; a face: top vertices (the bottom ones follow them)
fc_b:       ds 1
fc_ny:      ds 2
fc_u0:      ds 1
fc_u1:      ds 1
fc_v0:      ds 1
fc_v1:      ds 1
bb_x:       ds 2
bb_z:       ds 2
bb_hw:      ds 2            ; the half width bb_ox, bb_oz are for (0: none)
bb_ox:      ds 2
bb_oz:      ds 2
bb_y0:      ds 2
bb_y1:      ds 2
dr_pos:     ds 1            ; a door being drawn
dr_x:       ds 1
dr_z:       ds 1
dr_v:       ds 1
dr_t:       ds 1
dr_lo:      ds 2
dr_hi:      ds 2
dr_ulo:     ds 1
dr_uhi:     ds 1

; ---- the game (game_init clears from here to ram_end)
g_state:    ds 1            ; 0 playing, 1 dead, 2 level done
g_end:      ds 1            ; ticks since the end
dt:         ds 1            ; ticks (1/60 s) the last frame took, 1..8
frm_v0:     ds 2
fire_cd:    ds 1            ; five timers, run down by logic: this order
muzzle_t:   ds 1
recoil:     ds 1
hurt_t:     ds 1
pick_t:     ds 1
p_hp:       ds 1
p_ammo:     ds 1
p_score:    ds 1            ; in hundreds
kills:      ds 1
bob:        ds 1
moving:     ds 1
gun_x:      ds 1
gun_y:      ds 1
gun_f:      ds 1            ; pistol frame: 0 ready, 1 firing
hud_dirty:  ds 1            ; old fields (HF_*): page 0's in bits 0-2, page 1's in bits 4-6
hud_full:   ds 1            ; bit n: page n has no status bar yet
mv_fx:      ds 2
mv_fz:      ds 2
mv_s:       ds 1
mv_fs:      ds 2            ; forward, right (1, 0, -1)
mv_x:       ds 2
mv_z:       ds 2
bk_x:       ds 2
bk_z:       ds 2
bk_r:       ds 1
bk_c:       ds 4            ; cx0, cx1, cz0, cz1
sh_x:       ds 2
sh_z:       ds 2
sh_sx:      ds 2
sh_sz:      ds 2
sh_wall:    ds 2
sh_best:    ds 2
sh_hit:     ds 2
ls_x:       ds 1            ; line of sight: the cell, the steps, the error
ls_z:       ds 1
ls_n:       ds 1
ls_e:       ds 1
ls_dx:      ds 1
ls_dz:      ds 1
ls_sx:      ds 1
ls_sz:      ds 1
ai_rr:      ds 1            ; the standing monster that looks for the player this frame
ai_i:       ds 1
en_dx:      ds 1            ; cells from the monster to the player
en_dz:      ds 1
en_d:       ds 1
en_try:     ds 4
last_cx:    ds 1            ; the cell the pickup list is for
last_cz:    ds 1
cobj_n:     ds 1            ; pickups in the player's cell
cobj:       ds 4
numbuf:     ds 6
st_frames:  ds 2            ; statistics, read by the tests
st_ticks:   ds 1
st_nvert:   ds 1
st_nface:   ds 1
st_builds:  ds 2
taken:      ds 32           ; a bit per object: the player has it
door_pos:   ds 64           ; 0 shut .. 255 open
door_st:    ds 64           ; DS_*
door_tm:    ds 64           ; ticks an open door still waits
loose:      ds 16           ; ammo left by guards: cell x, z (x = 0: free), 8 of them

EN_TYPE:    equ 0           ; 0 guard, 1 dog
EN_STATE:   equ 1
EN_X:       equ 2
EN_Z:       equ 4
EN_HP:      equ 6
EN_T:       equ 7           ; ticks in this state
EN_DIR:     equ 8           ; 0 +x, 1 -x, 2 +z, 3 -z; FFh none
EN_FRAME:   equ 9
EN_FLAGS:   equ 10          ; bit 0 struck / fired, bit 1 walk frame
EN_TX:      equ 11          ; the cell it walks to
EN_TZ:      equ 12
EN_REM:     equ 13          ; units left to its centre (0: there)
EN_ANIM:    equ 14
EN_FACE:    equ 15          ; where a standing monster looks
EN_SIZE:    equ 16
enemies:    ds NENEMY * EN_SIZE
ram_end:
