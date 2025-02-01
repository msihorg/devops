#!/bin/bash
# make executable: chmod +x script.sh

# upgrade ubuntu 20.04 to 22.04
sudo apt update
sudo apt upgrade
sudo apt install update-manager-core
sudo do-release-upgrade
cat /etc/os-release

# upgrade ubuntu 22.04 to 24.04
sudo apt update
sudo apt upgrade
sudo apt install ubuntu-release-upgrader-core
cat /etc/os-release


#cleanup nginx website configs
sudo rm /etc/nginx/sites-available/*
sudo rm /etc/nginx/sites-enabled/*