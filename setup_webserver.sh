#!/bin/bash
# make executable: chmod +x script.sh

# Installation PowerShell
snap install powershell --classic

#Install the cot net SDK 9
sudo add-apt-repository ppa:dotnet/backports
sudo apt-get update
sudo apt-get install -y dotnet-sdk-9.0

#Install Nginx:
sudo apt install nginx -y
sudo systemctl start nginx
sudo systemctl enable nginx
sudo systemctl status nginx
sudo systemctl restatus nginx

# update firewall
sudo ufw allow from x.x.x.x/y to any port 80
sudo ufw allow from x.x.x.x/y to any port 443

