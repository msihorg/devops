sudo apt update
sudo apt install xrdp

sudo systemctl status xrdp

echo "gnome-session" > ~/.xsession

sudo ufw allow from x.x.x.x/y to any port 3389

sudo systemctl enable xrdp

sudo apt install xfce4
sudo systemctl restart xrdp