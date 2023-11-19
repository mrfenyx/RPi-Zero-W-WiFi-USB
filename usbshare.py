#!/usr/bin/python3
import time
import os
import subprocess
import logging
from watchdog.observers import Observer
from watchdog.events import *

# Set up logging
logging.basicConfig(level=logging.INFO)  # Set to logging.INFO to reduce verbosity
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
