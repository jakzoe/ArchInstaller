#!/bin/sh

added_monitor() {

  pattern="^(.*)>>(.*)$"

  if [[ $1 =~ $pattern ]]; then
    # event="${BASH_REMATCH[1]}"
    monitor_setup "${BASH_REMATCH[2]}"
  fi
}

monitor_setup() {

  if [[ $1 == *"HDMI-A-1"* ]]; then
   # 1920/1.2 = 1600 (when placing eDP-1 on the left)
    hyprctl keyword monitor HDMI-A-1,preferred,0x0,1
    hyprctl keyword monitor eDP-1,highres,1920x0,1.2
    return 0
  fi

  return 1
}

removed_monitor(){

  pattern="^(.*)>>(.*)$"

  if [[ $1 =~ $pattern ]]; then
    # event="${BASH_REMATCH[1]}"
    data="${BASH_REMATCH[2]}"

    if [[ $data == "HDMI-A-1" ]]; then
      hyprctl keyword monitor eDP-1,preferred,0x0,1
    fi
  fi
}

opened_window(){

  pattern="^(.*)>>(.*)$"

  if [[ $1 =~ $pattern ]]; then
    # event="${BASH_REMATCH[1]}"
    data="${BASH_REMATCH[2]}"

    # brave is not scaled correctly on startup when using wayland, this "fixes" the problem
    if [[ $data == *"brave-browser"* ]]; then
      hyprctl dispatch fullscreen ; sleep 0.5; hyprctl dispatch fullscreen
    fi
  fi
}

handle() {
  case $1 in
    monitoradded*) added_monitor $1;;
    monitorremoved*) removed_monitor $1;;
    openwindow*) opened_window $1;;
  esac
}

if monitor_setup "$(hyprctl monitors)"; then
  # when eDP-1 is on the right side
  hyprctl dispatch swapactiveworkspaces HDMI-A-1 eDP-1
fi

socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock | while read -r line; do handle "$line"; done
