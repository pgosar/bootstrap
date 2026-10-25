#!/bin/bash
# Prevent sleep when SSH sessions are active
while true; do
    ssh_active=false
    for id in $(loginctl list-sessions --no-legend | awk '{print $1}'); do
        if loginctl show-session "$id" | grep -q "Service=sshd"; then
            ssh_active=true
            break
        fi
    done

    if [ "$ssh_active" = true ]; then
        systemd-inhibit --what=sleep:idle --mode=block --who="ssh-inhibit" --why="Active SSH session" sleep 60
    else
        sleep 10
    fi
done
