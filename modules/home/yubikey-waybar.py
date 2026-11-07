import json
import math
import os
import socket
import struct
import subprocess
import sys
import threading
import time


def play_alert():
    rate = 24000
    samples = bytearray()
    for frequency in (880, 1100, 880):
        count = int(rate * 0.18)
        for i in range(count):
            envelope = min(1, i / (rate * 0.01), (count - 1 - i) / (rate * 0.01))
            samples.extend(struct.pack('<h', int(16000 * envelope * math.sin(2 * math.pi * frequency * i / rate))))
        samples.extend(b'\0\0' * int(rate * 0.12))
    pause = b'\0\0' * int(rate * 0.4)
    try:
        subprocess.run(
            [sys.argv[1], '--raw', '--rate=24000', '--channels=1', '--format=s16',
             '--media-role=Notification', '--volume=0.7', '-'],
            input=(samples + pause) * 3, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=6, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def emit(active):
    print(json.dumps({
        'text': '󰌋',
        'class': 'waiting' if active else 'idle',
        'tooltip': 'Touch your YubiKey' if active else 'YubiKey touch detector',
    }), flush=True)


path = os.path.join(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'),
                    'yubikey-touch-detector.socket')
emit(False)
while True:
    active = set()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(path)
            buffer = b''
            while chunk := client.recv(4096):
                buffer += chunk
                while len(buffer) >= 5:
                    event, buffer = buffer[:5], buffer[5:]
                    kind, state = event[:3], event[4:]
                    if event[3:4] != b'_' or kind not in (b'GPG', b'U2F', b'MAC') or state not in (b'0', b'1'):
                        continue
                    was_active = bool(active)
                    if state == b'1':
                        active.add(kind)
                    else:
                        active.discard(kind)
                    if bool(active) != was_active:
                        emit(bool(active))
                        if active:
                            threading.Thread(target=play_alert, daemon=True).start()
    except OSError:
        pass
    emit(False)
    time.sleep(1)
