#!/bin/sh
while :
do
        /usr/bin/logger "Restarting laserboss"
        /usr/bin/lua /root/laserboss.lua
        sleep 5
done
