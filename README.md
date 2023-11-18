# RPi-Zero-W-WiFi-USB
Use the Raspberry Pi Zero W as a WiFi USB Stick

## Goal

The goal is to use a Raspberry Pi Zero W as a USB Drive (for example, for your 3D printer) while being able to access it from your laptop or through Wi-Fi, as a network drive. In the case of a 3D printer, in this way you can export g-code to the shared folder and a couple of seconds later, it will be available to your device.

In case of Anycubic printers that can use their Mobile app, you can then directly initiate a print from it.

In general, you only have to select the file on your printer and that's it! No more plugging and unplugging the USB Stick!

**DISCLAIMER** : _I tried, tested and am currently using this setup but there may be a lot of reasons why it may not work for you. I also accept absolutely no responsibility in case something goes wrong, and you break any of your hardware, including the Raspberry Pi or your 3D printer. Do this at your own risk!_

## Bill of Materials

- Raspberry Pi Zero W
- 2x Micro USB to USB cables
- Power supply for the Raspberry Pi
- Micro-SD Card for Raspberry Pi (preferably 16 GB)
- OPTIONAL: Raspberry Pi Zero W Case

## Preparing the Raspberry Pi

1. Use the Raspberry Pi Imager or tool of choice to get the latest Raspberry Pi OS on the SD Card. Make sure you use the 32-bit Lite version!
2. There are plenty of guides how to get this done, including remote access through SSH (needed!)
3. Perform first boot, log through SSH and ensure you have access to the OS.
4. Optional but recommended: perform a system update

```bash
sudo apt update && sudo apt upgrade -y
```

## Enabling the USB Driver

You will have to edit some configuration files.
```bash
sudo nano /boot/config.txt
```
Scroll to the last line of the file and add the following line:
```
dtoverlay=dwc2
```
Close and save (CTRL+X, press Y and Enter)

Next, edit the modules file:
```bash
sudo nano /etc/modules
```
At the end of the file add this:
```
dwc2
```
Close and save (CTRL+X, press Y and Enter)

Next, you will make sure the USB driver is enabled on boot.
```bash
sudo nano /boot/commandline.txt
```
This is a bit tricky. You will need to add the text below **at the end of the existing line (don't add a new line!)** Make sure there is a space between the last command and this one. At the end of the line there should be a space and after the command line, an empty line.
```
modules-load=dwc2
```
**OPTIONAL** : disable power saving for wlan
```bash
sudo iw wlan0 set power_save off
```
## "Fixing" the USB Data Cable

Normally a USB cable also provides current to the device that is connected to the port. In order to ensure there is no interference between the Raspberry Pi and your printer, you need to ensure that there is no current flowing through the cable used to connect them. To do this, follow this tutorial: [https://community.octoprint.org/t/put-tape-on-the-5v-pin-why-and-how/13574](https://community.octoprint.org/t/put-tape-on-the-5v-pin-why-and-how/13574)
Once this is done, you can connect this cable to the Data port on the Raspberry Pi (NOT the power port!) and the other end, for now, to your laptop / PC.

## Creating a USB File

Next, you need to create a file that will contain the data you want to share with the printer.
```bash
sudo dd bs=1M if=/dev/zero of=/piusb.bin count=2048
```
**NOTE** : the last parameter, "count" determines the size of the "USB Drive" in MBs. In the code above, it will be 2GB. If you want it bigger, go bigger but leave some free space on the SD Card 😉.

Once the file is created, you need to format it so that the printer can read it.
```bash
sudo mkdosfs /piusb.bin -F 32 -I
```
## Mounting the USB File

Start by creating a folder for the mount:
```bash
sudo mkdir /mnt/usb_share
```
Just to make sure permissions are not an issue:
```bash
sudo chmod 777 /mnt/usb_share/
```
Next, you need to add it to fstab
```bash
sudo nano /etc/fstab
```
Add this to the end of the file:
```bash
/piusb.bin /mnt/usb_share vfat users,umask=000 0 2
```
Close and save (CTRL+X, press Y and Enter)

Manually reload fstab
```bash
sudo mount -a
```
## Testing the USB Mounting / Unmounting

To simulate connecting the USB, execute this:
```bash
sudo /sbin/modprobe g_multi file=/piusb.bin stall=0 removable=1
```
At this point, a new _USB Drive_ should be visible in your file explorer.

To disconnect it, run this:
```bash
sudo /sbin/modprobe g_multi -r
```
The drive should disappear. Running the first command again will reconnect it.

If this works, you're good so far 😉

## Configuring Samba for Remote File Access

In the next steps you will make the folder available on the network. This way you can drop files there from your laptop / PC. You will use Samba for this. Install it:
```bash
sudo apt-get update
sudo apt-get install samba winbind -y
```
Next, you need to configure it. Edit the configuration file.
```bash
sudo nano /etc/samba/smb.conf
```
You need to add the lines below, which create a new network share:
```bash
[usb]

browseable = yes
path = /mnt/usb_share
guest ok = yes
read only = no
create mask = 777
directory mask = 777
```
Close and save (CTRL+X, press Y and Enter)

Restart the Samba service
```bash
sudo systemctl restart smbd.service
```
## Accessing the folder from you PC

Find the IP of the Raspberry Pi (for example, running ifconfig on the RasPi). Then, on your PC go to \\\<RPi\_IP\> and you should see one shared folder called "usb".

## Making the Magic Happen – Automated USB Device Reconnect

In order to see changes, the USB needs to be disconnected and reconnected after a change. Since the whole point is to not do this physically, you will need to create a script using a so-called watchdog to do it for you. You will use Python for this. First, install it and the watchdog that looks for changes:
```bash
sudo apt-get install python3-pip
sudo apt-get install python3-watchdog
```
Next, create a file to contain the script needed to make magic:
```bash
sudo nano /usr/local/share/usbshare.py
```
Inside this file, paste the following code:

```python
#!/usr/bin/python3
import time
import os
import subprocess
import logging
from watchdog.observers import Observer
from watchdog.events import *

# Set up logging
logging.basicConfig(level=logging.DEBUG)  # Set to logging.INFO to reduce verbosity
logger = logging.getLogger(__name__)

CMD_MOUNT = "sudo /sbin/modprobe g_multi file=/piusb.bin stall=0 removable=1"
CMD_UNMOUNT = "sudo /sbin/modprobe g_multi -r"
CMD_SYNC = "sync"

WATCH_PATH = "/mnt/usb_share"
ACT_EVENTS = [DirDeletedEvent, DirMovedEvent, FileDeletedEvent, FileModifiedEvent, FileMovedEvent]
ACT_TIME_OUT = 5   # This is the time in seconds that the watchdog waits after a change is detected. Usually, if you just save a g-code file this is enough.

class DirtyHandler(FileSystemEventHandler):
    def __init__(self):
        self.reset()
        logger.debug("DirtyHandler initialized.")

    def on_any_event(self, event):
        if type(event) in ACT_EVENTS:
            self._dirty = True
            self._dirty_time = time.time()
            logger.debug(f"Event detected: {event}. Marking as dirty.")

    @property
    def dirty(self):
        return self._dirty

    def dirty_time(self):
        return self._dirty_time

    def reset(self):
        self._dirty = False
        self._dirty_time = 0
        self._path = None
        logger.debug("DirtyHandler reset.")

def run_command(command):
    try:
        result = subprocess.run(command, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        logger.debug(f"Output of {command}: {result.stdout}")
        logger.debug(f"Error of {command}, if any: {result.stderr}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error executing {command}: {e}")

# Unmount & Mount the device
logger.debug("Unmounting the device.")
run_command(CMD_UNMOUNT)
logger.debug("Mounting the device.")
run_command(CMD_MOUNT)

evh = DirtyHandler()
observer = Observer()
observer.schedule(evh, path=WATCH_PATH, recursive=True)
observer.start()
logger.debug("Observer started to monitor the path.")

try:
    while True:
        if evh.dirty:
            time_out = time.time() - evh.dirty_time()
            logger.debug(f"Change detected. Timeout: {time_out}s.")

            if time_out >= ACT_TIME_OUT:
                logger.debug("Timeout exceeded. Unmounting the device.")
                run_command(CMD_UNMOUNT)
                time.sleep(1)
                logger.debug("Syncing after unmounting.")
                run_command(CMD_SYNC)
                time.sleep(1)
                logger.debug("Remounting the device.")
                run_command(CMD_MOUNT)
                evh.reset()

            time.sleep(1)
        else:
            logger.debug("No changes detected. Sleeping for 1 second.")
            time.sleep(1)

except KeyboardInterrupt:
    logger.debug("KeyboardInterrupt received. Stopping observer.")
    observer.stop()
    observer.join()
    logger.debug("Observer stopped and joined.")
```

Close and save (CTRL+X, press Y and Enter)

You could now test to see if the script works. To start it manually, run this:
```bash
sudo python /usr/local/share/usbshare.py
```
You should see some log outputs in the console. Now open the network share and add a new file. The console should say that a change was detected. After 5 seconds, the USB drive gets unmounted, then re-mounted. On the USB Drive you should see the added file after about 10-15 seconds.

To stop the script execution, **press CTRL + C**.

# Making the Script into a Service

You want this script to run as a service, every time the Raspberry Pi reboots. To do this, create a new service file:
```bash
sudo nano /etc/systemd/system/usbshare.service
```
Add the following lines to it:
```bash
[Unit]

Description=Watchdog for USB Share
After=multi-user.target

[Service]

Type=idle
ExecStart=/usr/bin/python /usr/local/share/usbshare.py

[Install]
WantedBy=multi-user.target
```
Close and save (CTRL+X, press Y and Enter)

Reload the systemctl daemon to make the new service visible to the system:
```bash
sudo systemctl daemon-reload
```
Finally, enable the service:
```bash
sudo systemctl enable usbshare.service
```
# Reboot and see if it works

This is it! Now, reboot your Raspberry Pi:
```bash
sudo reboot
```
After about 1 minute, the system should be back online. You should see the USB Drive and the Network share. Consider mapping the share as a network drive. If this works, connect the Raspberry Pi to your Printer's USB port.

To test things out, open your favourite slicer, generate some g-code and save it to the network drive. In about 10-20 seconds, the code should be visible in your printer, on the USB drive.

If it works, good job! 👏🥂🥳🎉🎊

If not, I'm sorry! 😢😭😿
