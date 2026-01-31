#!/usr/bin/python3
import time
import os
import subprocess
import logging
import threading
import sys
from watchdog.observers import Observer
from watchdog.events import *

# Set up logging
logging.basicConfig(level=logging.INFO)  # Set to logging.INFO to reduce verbosity
logger = logging.getLogger(__name__)

CMD_MOUNT = "sudo /sbin/modprobe g_multi file=/piusb.bin stall=0 removable=1"
CMD_UNMOUNT = "sudo /sbin/modprobe g_multi -r"
CMD_SYNC = "sync"

WATCH_PATH = "/mnt/usb_share"
ACT_EVENTS = [
    DirDeletedEvent, DirMovedEvent, DirCreatedEvent,
    FileDeletedEvent, FileModifiedEvent, FileMovedEvent, FileCreatedEvent
]
ACT_TIME_OUT = 5   # seconds to wait after last event before cycling the gadget
CMD_RETRIES = 3
RETRY_DELAY = 1.0

class DirtyHandler(FileSystemEventHandler):
    def __init__(self):
        self._lock = threading.Lock()
        self.reset()
        logger.debug("DirtyHandler initialized.")

    def on_any_event(self, event):
        if type(event) in ACT_EVENTS:
            with self._lock:
                self._dirty = True
                self._dirty_time = time.time()
            logger.debug(f"Event detected: {event}. Marking as dirty.")

    @property
    def dirty(self):
        with self._lock:
            return self._dirty

    def dirty_time(self):
        with self._lock:
            return self._dirty_time

    def reset(self):
        with getattr(self, '_lock', threading.Lock()):
            self._dirty = False
            self._dirty_time = 0
            self._path = None
        logger.debug("DirtyHandler reset.")


def run_command(command, retries=CMD_RETRIES, retry_delay=RETRY_DELAY):
    """Run a shell command with retries. Returns (success, stdout, stderr)."""
    attempt = 0
    while attempt < retries:
        try:
            result = subprocess.run(command, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            logger.debug(f"Output of {command}: {result.stdout}")
            if result.stderr:
                logger.debug(f"Error output of {command}: {result.stderr}")
            return True, result.stdout, result.stderr
        except subprocess.CalledProcessError as e:
            attempt += 1
            logger.warning(f"Attempt {attempt}/{retries} failed for command: {command}. Error: {e}. Retrying in {retry_delay}s")
            time.sleep(retry_delay)
            retry_delay *= 2
    logger.error(f"All {retries} attempts failed for command: {command}")
    return False, '', ''


def ensure_watch_path(timeout=30):
    """Wait for the watch path to exist (and be mounted if possible)."""
    logger.info(f"Waiting up to {timeout}s for watch path {WATCH_PATH} to be available...")
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(WATCH_PATH):
            # Prefer it to be mounted, but accept existing directory
            if os.path.ismount(WATCH_PATH):
                logger.info(f"Watch path {WATCH_PATH} is mounted and ready.")
                return True
            else:
                logger.info(f"Watch path {WATCH_PATH} exists but is not mounted. Attempting 'mount -a'...")
                _ok, _out, _err = run_command("sudo mount -a")
                if _ok and os.path.ismount(WATCH_PATH):
                    logger.info(f"Mounted {WATCH_PATH} successfully.")
                    return True
                # else continue waiting
        time.sleep(1)
    logger.error(f"Watch path {WATCH_PATH} not available after {timeout}s")
    return False


# Ensure WATCH_PATH is present before starting
if not ensure_watch_path():
    logger.error("Required watch path is not available; exiting.")
    sys.exit(1)

# Try to ensure gadget is in a known state
logger.info("Ensuring gadget is in a known state: syncing, unmounting, then mounting.")
run_command(CMD_SYNC)
ok, out, err = run_command(CMD_UNMOUNT)
if not ok:
    logger.debug("g_multi module might not have been loaded or could not be removed; continuing to mount attempt.")
ok, out, err = run_command(CMD_MOUNT)
if not ok:
    logger.error("Failed to mount the gadget initially. Continuing; service will retry on events.")

# Start observer after Watch path is ready
evh = DirtyHandler()
observer = Observer()
observer.schedule(evh, path=WATCH_PATH, recursive=True)
observer.start()
logger.info("Observer started to monitor the path.")

try:
    while True:
        if evh.dirty:
            time_out = time.time() - evh.dirty_time()
            logger.debug(f"Change detected. Timeout: {time_out}s.")

            if time_out >= ACT_TIME_OUT:
                logger.info("Debounce period elapsed. Cycling the USB gadget.")

                # Flush buffers first
                run_command(CMD_SYNC)

                # Unmount/remove gadget
                ok, _, _ = run_command(CMD_UNMOUNT)
                if not ok:
                    logger.warning("Initial unmount failed; retrying removal.")
                    ok, _, _ = run_command(CMD_UNMOUNT)

                time.sleep(1)

                # Remount gadget
                ok, _, _ = run_command(CMD_MOUNT)
                if not ok:
                    logger.error("Failed to remount gadget after unmount. Will continue and wait for next event.")
                else:
                    logger.info("Gadget remounted successfully.")
                    evh.reset()

            time.sleep(1)
        else:
            logger.debug("No changes detected. Sleeping for 1 second.")
            time.sleep(1)

except KeyboardInterrupt:
    logger.info("KeyboardInterrupt received. Stopping observer.")
    observer.stop()
    observer.join()
    logger.info("Observer stopped and joined.")
except Exception as e:
    logger.exception(f"Unhandled exception in main loop: {e}")
    observer.stop()
    observer.join()
    sys.exit(1)
