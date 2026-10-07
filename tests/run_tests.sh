#!/bin/bash
# run_tests.sh - runs the cartridge in openMSX (the V9968 + geo3d fork) and checks it
#
#   run_tests.sh [scenario ...]     default: poses walk combat pickup death win dogs
#     poses    freezes the game at a list of poses and compares the page geo3d
#              painted with tools/sim.py (geo3d's reference model), byte by byte
#     walk     walks east from the start: two doors open by themselves and shut
#     combat   shoots a guard dead, takes the ammo it leaves: shot, monsters, HUD
#     pickup   a hurt player walks over food; crosses give points
#     death    stands near a guard until dead, then restarts from the end screen
#     win      walks into the elevator: the end screen, back to the title
#     dogs     shoots a dog, is bitten by another
#     prof     frame times (prof1: standing only; PROFMARKS="label ..." picks the marks)
#     hits     calls of the costly routines per frame
#     docs, tour, flash, title   SHOT=1: screenshots (no checks)
#   PROFILE=88 runs the 88h ROM on a machine with the V9968 cartridge
#   (-ext HRA_V9968 -ext geo3d88); MACHINE=... picks another machine.
#   SHOT=1 opens a window, runs in real time and saves the `shot` pictures.
# From WSL the Windows build of the emulator is used (OPENMSX=...openmsx.exe,
# its arguments become Windows paths); a Linux build works the same way.
# Writes out/test/<scenario>/ (log.txt, page dumps, PNGs). Exit 1 on a failure.
cd "$(dirname "$0")/.."
OPENMSX=${OPENMSX:-/mnt/c/Projects/mmsoft/openmsx-geo3d/openmsx.exe}
PROFILE=${PROFILE:-98}
[ -f out/MSXWOLF_$PROFILE.ROM ] || { echo "build first (build.sh)"; exit 2; }
if [ "$PROFILE" = 88 ]; then
  args="-machine ${MACHINE:-C-BIOS_MSX2+} -ext HRA_V9968 -ext geo3d88"; export VDPNAME=V9968
else
  args="-machine ${MACHINE:-C-BIOS_V9968_JP} -ext geo3d"; export VDPNAME=VDP
fi
case "$OPENMSX" in
  *.exe) w() { wslpath -m "$(realpath "$1")"; } ;;
  *)     w() { realpath "$1"; }; export SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-dummy} SDL_AUDIODRIVER=dummy ;;
esac
export SHOT=${SHOT:-0}

POSES=${POSES:-"29.5:57.5:64 33.5:55.5:0 34.5:50.5:0 34.5:34.5:192 37.5:33.5:64 10.5:46.5:64 30.5:11.5:64 47.5:33.5:64 34.3:31.2:16 31.2:57.3:100 34.5:52.3:0 20.5:17.5:128 2.5:33.5:32 47.6:45.3:200 33.5:51.75:0 34.5:49.3:128"}

script_of() {
  case $1 in
    poses)
      s="freeze 1;start"
      i=0
      for p in $POSES; do
        IFS=: read -r x z yaw <<< "$p"
        s="$s;pose $x $z $yaw;frames 4;dump pose_$i;shot pose_$i"
        i=$((i + 1))
      done
      echo "$s" ;;
    walk)     # east from the start: doors 20 and 21 open by themselves, then shut
      echo "freeze 1;start;freeze 0;shot walk_0;keys 1;wait 0.6;shot walk_1;expect door_st+20 == 1;wait 0.8;shot walk_2;wait 1.6;keys 0;shot walk_3;expect p_cx >= 33;expect door_pos+20 > 200;expect p_cz == 57;wait 7;expect door_st+20 == 0;expect door_pos+20 == 0;expect16 st_frames > 100;log walk" ;;
    combat)   # the guard of the middle hall, 3.5 cells ahead and looking this way
      echo "freeze 1;start;pose 34.5 33.5 64;frames 3;freeze 0;shot combat_0;keys 16;wait 0.1;psg 8 > 0;shot combat_1;wait 3;keys 0;wait 1;shot combat_2;expect kills == 1;expect p_score == 1;expect g_state == 0;expect p_ammo < 8;poke p_ammo 1;keys 1;wait 1.5;keys 0;shot combat_3;expect p_ammo == 5;log combat" ;;
    pickup)   # hurt, a cell south of the food at (37, 57); then two crosses in the closet
      echo "freeze 1;start;pose 37.5 58.5 0;frames 3;poke p_hp 40;freeze 0;shot pickup_0;keys 1;wait 0.5;keys 0;wait 0.3;shot pickup_1;expect p_hp == 50;expect taken+14 == 4;freeze 1;pose 42.5 10.5 192;frames 3;freeze 0;wait 0.3;expect p_score == 1;keys 1;wait 0.5;keys 0;shot pickup_2;expect p_score == 2;log pickup" ;;
    death)    # two cells from a guard with one point of health; then the end screen
      echo "freeze 1;start;pose 36.5 33.5 64;frames 3;poke p_hp 1;freeze 0;wait 6;shot death_0;expect p_hp == 0;expect g_state == 1;wait 3;shot death_1;keys 16;wait 0.3;keys 0;wait 1;shot death_2;log title;keys 16;wait 0.3;keys 0;wait 1.5;expect p_hp == 100;expect g_state == 0;expect kills == 0;expect16 st_frames > 5;expect pal_cur == 0;log restarted" ;;
    win)      # the elevator's door (the two guards of its room put out of the way)
      echo "freeze 1;start;pose 22.5 47.5 64;poke enemies+273 5;poke enemies+289 5;frames 3;freeze 0;shot win_0;keys 1;wait 1.2;shot win_1;wait 2;keys 0;expect g_state == 2;shot win_2;wait 3;shot win_3;log win;keys 16;wait 0.3;keys 0;wait 1;shot win_4;expect16 st_frames < 400" ;;
    dogs)     # the kennel: one dog two cells ahead, shot; the other comes and bites
      echo "freeze 1;start;pose 58.5 43.5 192;frames 3;freeze 0;keys 16;wait 0.5;keys 0;shot dogs_0;expect kills == 1;expect p_score == 2;wait 3;shot dogs_1;mons;expect p_hp < 100;expect g_state == 0;log dogs" ;;
    flash)    # the shot's flash held on (pictures only)
      echo "freeze 1;start;pose 34.5 33.5 64;frames 3;poke muzzle_t 250;wait 1.5;shot flash;poke muzzle_t 0;poke hurt_t 250;wait 1.5;shot hurt" ;;
    docs)     # pictures for the README (SHOT=1)
      echo "wait 1;shot title;freeze 1;start;wait 1;shot start;pose 35.5 33.5 64;wait 1.5;shot guard;pose 34.5 46.5 0;wait 1.5;shot hall;pose 20.5 14.5 128;wait 1.5;shot wood;pose 9.5 32.5 100;wait 1.5;shot blue;pose 55.2 33.5 64;wait 1.5;shot kennel" ;;
    title)
      echo "wait 1;shot title;wait 0.5;shot title2" ;;
    prof)     # where a frame goes: standing, walking and turning, a fight
      echo "freeze 1;start;freeze 0;wait 0.3;log standing;prof 2;keys 1;log walking;prof 2.5;keys 9;log walk+turn;prof 3;freeze 1;pose 34.5 33.5 64;frames 3;freeze 0;keys 16;log fight;prof 3;keys 0;freeze 1;pose 34.5 46.5 0;frames 3;log long hall;prof 2" ;;
    prof1)    # the same, standing at the start only (PROFMARKS="label ..." picks the marks)
      echo "freeze 1;start;freeze 0;wait 0.3;log standing;prof 1" ;;
    hits)     # how often the costly routines run in a frame
      echo "freeze 1;start;freeze 0;wait 0.3;hits 1 area_seen grid_at bb_emit mulq14 face_out vtx_pair ne_wall nw_set dr_one sin_a frac8;freeze 1;pose 34.5 33.5 64;frames 3;hits 1 area_seen grid_at bb_emit mulq14 face_out vtx_pair ne_wall nw_set dr_one sin_a frac8" ;;
    tour)
      echo "freeze 1;start;freeze 0;wait 0.5;shot tour_0;keys 1;wait 1.5;shot tour_1;wait 1.5;shot tour_2;keys 5;wait 0.65;shot tour_3;keys 1;wait 1.5;shot tour_4;wait 1.5;shot tour_5;keys 17;wait 2;shot tour_6;keys 0;wait 1;shot tour_7" ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
  esac
}

rc=0
for scen in ${@:-poses walk combat pickup death win dogs}; do
  dir=out/test/${scen}${TAG:+_$TAG}
  rm -rf "$dir"
  mkdir -p "$dir"
  awk -F'[:\t$ ]+' '/^[A-Za-z_0-9]+:\tequ \$/ { printf "set ::A(%s) 0x%s\n", $1, $NF }' \
    out/labels_$PROFILE.txt > "$dir/labels.tcl"
  export LABELS="$(w "$dir/labels.tcl")" OUTDIR="$(w "$dir")"
  export SCRIPT="$(script_of $scen)"
  export WSLENV=LABELS:OUTDIR:SCRIPT:SHOT:VDPNAME:PROFMARKS
  rom="$(w out/MSXWOLF_$PROFILE.ROM)"
  script="$(w tests/run.tcl)"
  (cd "$(dirname "$OPENMSX")" && timeout 900 "./$(basename "$OPENMSX")" $args \
     -cart "$rom" -romtype ASCII16 -script "$script" > /dev/null 2>&1)
  echo "== $scen ($PROFILE h)"
  if ! grep -q " END" "$dir/log.txt" 2>/dev/null; then echo "FAIL: the run did not end"; rc=1; continue; fi
  grep -E " E | L | M | PROF| HITS" "$dir/log.txt"
  grep -q " E FAIL" "$dir/log.txt" && rc=1
  if [ "$scen" = poses ]; then
    python3 tests/compare.py "$dir" || rc=1
  fi
done
[ $rc = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $rc
