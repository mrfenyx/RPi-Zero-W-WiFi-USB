#!/bin/bash

# Configuration Variables
USB_FILE_SIZE_MB=2048 # Size of the USB file in Megabytes
REQUIRED_SPACE_MB=$((USB_FILE_SIZE_MB + 1024)) # Required space including buffer
MOUNT_FOLDER="/mnt/usb_share"
USE_EXISTING_FOLDER="no"
DRIVER_TO_USE="g_multi"
if [[ "g_mass_storage" = "$1" ]]; then
    DRIVER_TO_USE="g_mass_storage"
fi


# Known compatible hardware models
COMPATIBLE_MODELS=("Raspberry Pi Zero W Rev 1.1" "Raspberry Pi Zero 2 W Rev 1.0")

# Check the hardware model
HARDWARE_MODEL=$(cat /proc/device-tree/model)

# Function to check if the model is in the list of compatible models
is_model_compatible() {
    for model in "${COMPATIBLE_MODELS[@]}"; do
        if [[ $model == $1 ]]; then
            return 0
        fi
    done
    return 1
}

# Perform the hardware check
if is_model_compatible "$HARDWARE_MODEL"; then
    echo "Detected compatible hardware: $HARDWARE_MODEL"
    COMPATIBILITY_CHECK_PASSED=true
else
    echo "Detected hardware: $HARDWARE_MODEL"
    echo "This hardware model is not in the list of known compatible models. The script might not work as expected."
    echo "Do you want to continue anyway? (y/n)"
    read continue_choice
    if [[ "$continue_choice" != "y" && "$continue_choice" != "yes" ]]; then
        echo "Aborting script due to potential compatibility issues."
        exit 1
    else
        COMPATIBILITY_CHECK_PASSED=false
    fi
fi

# Function to install packages and check for errors
install_packages() {
    # Update package lists
    sudo apt-get update
    if [ $? -ne 0 ]; then
        echo "Failed to update package lists."
        return 1
    fi

    # Upgrade existing packages
    sudo apt-get upgrade -y
    if [ $? -ne 0 ]; then
        echo "Failed to upgrade packages."
        return 1
    fi

    # Install new packages
    sudo apt-get install -y samba winbind python3-pip python3-watchdog
    return $? # Return the exit status of the last command executed
}

# Install necessary packages
while true; do
    install_packages
    if [ $? -eq 0 ]; then
        echo "Packages installed successfully."
        break
    else
        echo "An error occurred during package installation."
        echo "Do you want to retry? (yes/no):"
        read user_choice
        if [[ "$user_choice" != "yes" && "$user_choice" != "y" ]]; then
            echo "Installation aborted by the user."
            exit 1
        fi
    fi
done

# Function to append text to a file, check for existing text, and verify successful writing
append_text_to_file() {
    local text="$1"
    local file="$2"
    local identifier="$3"

    # Check if the identifier is provided and exists in the file
    if [[ -n "$identifier" && $(grep -Fxc "$identifier" "$file") -ne 0 ]]; then
        echo "The identifier '$identifier' already exists in $file."
        return 1
    fi

    # Append text to the file
    echo "$text" | sudo tee -a "$file" > /dev/null
    local status=$?

    # Check if the write operation was successful
    if [ $status -ne 0 ]; then
        echo "Failed to write to $file."
        return 1
    else
        echo "Text appended successfully to $file."
        return 0
    fi
}

# Determine the correct directory for boot files
BOOT_DIR="/boot"
if [ -d "/boot/firmware" ]; then
    BOOT_DIR="/boot/firmware"
fi

# Enabling USB Driver
append_text_to_file "dtoverlay=dwc2" "$BOOT_DIR/config.txt" "dtoverlay=dwc2"
append_text_to_file "dwc2" "/etc/modules" "dwc2"

# Carefully edit commandline.txt to append 'modules-load=dwc2' at the end of the line
if ! grep -q "modules-load=dwc2" $BOOT_DIR/cmdline.txt; then
    sudo sed -i '$ s/$/ modules-load=dwc2/' $BOOT_DIR/cmdline.txt && echo "Modified $BOOT_DIR/cmdline.txt successfully."
else
    echo "Modification already exists in $BOOT_DIR/cmdline.txt."
fi

# Disabling power-saving for Wlan
sudo iw wlan0 set power_save off

# Function to create USB file
create_usb_file() {
    sudo dd bs=1M if=/dev/zero of=/piusb.bin count=$1
    sudo mkdosfs /piusb.bin -F 32 -I
}

# Creating a USB File
while true; do
    AVAILABLE_SPACE_KB=$(df --output=avail / | tail -1 | xargs)
    AVAILABLE_SPACE_MB=$((AVAILABLE_SPACE_KB / 1024))
    MAX_POSSIBLE_FILE_SIZE_MB=$((AVAILABLE_SPACE_MB - 1024)) # Max size considering buffer

    if [ ! -f "/piusb.bin" ]; then
        if [ "$AVAILABLE_SPACE_MB" -ge "$REQUIRED_SPACE_MB" ]; then
            create_usb_file $USB_FILE_SIZE_MB
            break
        else
            echo "Not enough space available. Required: $REQUIRED_SPACE_MB MB, Available: $AVAILABLE_SPACE_MB MB"
            echo "1. Create file with maximum available size ($MAX_POSSIBLE_FILE_SIZE_MB MB)"
            echo "2. Enter a new size manually"
            echo "3. Abort"
            echo "Please choose an option (1, 2, or 3):"
            read user_choice
            case $user_choice in
                1)
                    create_usb_file $MAX_POSSIBLE_FILE_SIZE_MB
                    break
                    ;;
                2)
                    echo "Enter the new size in MB (less than $MAX_POSSIBLE_FILE_SIZE_MB):"
                    read new_size
                    USB_FILE_SIZE_MB=$new_size
                    REQUIRED_SPACE_MB=$((USB_FILE_SIZE_MB + 1024))
                    ;;
                3)
                    echo "USB file creation aborted."
                    exit 1
                    ;;
                *)
                    echo "Invalid option. Please try again."
                    ;;
            esac
        fi
    else
        echo "/piusb.bin already exists"
        break
    fi
done

# Mounting USB File
if [ -d "$MOUNT_FOLDER" ]; then
    echo "Mount folder $MOUNT_FOLDER already exists."
    echo "Do you want to use this existing folder? (y/n)"
    read use_existing
    if [[ "$use_existing" =~ ^(yes|y)$ ]]; then
        USE_EXISTING_FOLDER="yes"
    else
        echo "Do you want to create a different folder? (y/n)"
        read create_new
        if [[ "$create_new" =~ ^(yes|y)$ ]]; then
            echo "Enter the name for the new mount folder (e.g., /mnt/new_folder):"
            read new_folder
            MOUNT_FOLDER=$new_folder
            sudo mkdir "$MOUNT_FOLDER"
            sudo chmod 777 "$MOUNT_FOLDER"
        else
            echo "Mounting process aborted."
            exit 1
        fi
    fi
fi

if [ "$USE_EXISTING_FOLDER" = "no" ]; then
    sudo mkdir "$MOUNT_FOLDER"
    sudo chmod 777 "$MOUNT_FOLDER"
fi
append_text_to_file "/piusb.bin $MOUNT_FOLDER vfat users,umask=000 0 2" "/etc/fstab" "/piusb.bin $MOUNT_FOLDER vfat users,umask=000 0 2"
sudo mount -a

# Configure Samba
samba_block=$(cat <<'EOT'
[usb]
    browseable = yes
    path = /mnt/usb_share
    guest ok = yes
    read only = no
    create mask = 777
    directory mask = 777
EOT
)
append_text_to_file "$samba_block" "/etc/samba/smb.conf" "[usb]"

# Restart Samba services
sudo systemctl restart smbd
ACTIVE_STATUS=$(systemctl is-active usbshare.service)
if [[ "$ACTIVE_STATUS" = "active" ]]; then
    echo "Service is currently active, shutting down"
    sudo systemctl stop usbshare.service
    sudo systemctl disable usbshare.service
    sudo modprobe g_multi -r
    sudo modprobe g_mass_storage -r
    sudo systemctl daemon-reload
fi
# Copy usbshare.py script
if [ -f "usbshare.py" ]; then
    sudo cp usbshare.py /usr/local/share/usbshare.py
    sudo chmod +x /usr/local/share/usbshare.py
    if [[ "$DRIVER_TO_USE" = "g_mass_storage" ]]; then
        sudo sed -i 's/g_multi/g_mass_storage/g' /usr/local/share/usbshare.py
    fi
else
    echo "usbshare.py not found"
    exit 1
fi

# Create systemd service for usbshare.py
usbshare_service_block=$(cat <<'EOT'
[Unit]
Description=Watchdog for USB Share
After=multi-user.target

[Service]
Type=idle
ExecStart=/usr/bin/python3 /usr/local/share/usbshare.py

[Install]
WantedBy=multi-user.target
EOT
)
append_text_to_file "$usbshare_service_block" "/etc/systemd/system/usbshare.service" "[Unit]"

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable usbshare.service
sudo systemctl start usbshare.service

# Feedback request for new hardware models
if [ "$COMPATIBILITY_CHECK_PASSED" = false ]; then
    echo "It looks like you ran this script on a different hardware model."
    echo "If everything worked as expected, please consider creating a new issue in the repository:"
    echo "https://github.com/mrfenyx/RPi-Zero-W-WiFi-USB"
    echo "This will help us to update the list of known compatible models. Thank you!"
fi

# Optional reboot
echo "Setup complete. It's recommended to reboot the system. Do you want to reboot now? (y/n)"
read reboot_choice
if [[ "$reboot_choice" =~ ^(yes|y)$ ]]; then
  sudo reboot
else
  echo "Reboot cancelled. Please reboot manually later."
fi
