#!/bin/bash
SRC="/data/replicas/minecraft/"
KEY="/home/chilly/.ssh/minecraft_sync"
PC="chilly@100.91.239.107"
MAC="chilly@100.89.119.15"
DEST="minecraft/"
/usr/bin/rsync -az --delete -e "ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" "$SRC" "$PC:$DEST"
/usr/bin/rsync -az --delete -e "ssh -i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10" "$SRC" "$MAC:$DEST"
