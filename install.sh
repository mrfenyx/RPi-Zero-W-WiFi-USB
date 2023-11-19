#!/bin/bash

# Configuration Variables
USB_FILE_SIZE_MB=2048 # Size of the USB file in Megabytes

# Clone the repository
git clone https://github.com/mrfenyx/RPi-Zero-W-WiFi-USB.git
cd RPi-Zero-W-WiFi-USB

# Install necessary packages
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y samba winbind python3-pip python3-watchdog

# Enabling USB Driver
echo "dtoverlay=dwc2" | sudo tee -a /boot/config.txt
echo "dwc2" | sudo tee -a /etc/modules

# Carefully edit commandline.txt to append 'modules-load=dwc2' at the end of the line
sudo sed -i '$ s/$/ modules-load=dwc2/' /boot/commandline.txt

# Disabling power-saving for Wlan
sudo iw wlan0 set power_save off

# Creating a USB File
sudo dd bs=1M if=/dev/zero of=/piusb.bin count=$USB_FILE_SIZE_MB
sudo mkdosfs /piusb.bin -F 32 -I

# Mounting USB File
sudo mkdir /mnt/usb_share
sudo chmod 777 /mnt/usb_share/
echo "/piusb.bin /mnt/usb_share vfat users,umask=000 0 2" | sudo tee -a /etc/fstab
sudo mount -a

# Configure Samba
cat <<EOT | sudo tee -a /etc/samba/smb.conf
[usb]
    path = /mnt/usb_share
    writeable=Yes
    create mask=0777
    directory mask=0777
    public=no
EOT

# Restart Samba services
sudo systemctl restart smbd

# Copy usbshare.py script
sudo cp usbshare.py /usr/local/share/usbshare.py
sudo chmod +x /usr/local/share/usbshare.py

# Create systemd service for usbshare.py
cat <<EOT | sudo tee /etc/systemd/system/usbshare.service
[Unit]
Description=Watchdog for USB Share
After=multi-user.target

[Service]
Type=idle
ExecStart=/usr/bin/python3 /usr/local/share/usbshare.py

[Install]
WantedBy=multi-user.target
EOT

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable usbshare.service
sudo systemctl start usbshare.service

# Optional reboot
echo "Setup complete. It's recommended to reboot the system. Do you want to reboot now? (y/n)"
read reboot_choice
if [ "$reboot_choice" == "y" ]; then
  sudo reboot
fi
