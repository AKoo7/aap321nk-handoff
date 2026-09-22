#!/usr/bin/env python3
"""Talk to the unit's UART through a tiny TCP broadcast broker.

The box has no way to give you a shell when both /etc persistence and ssh are gone; the serial
console is the way back.  Keep the port open to a broker so several tools can read/write it:

    socat -d -d /dev/ttyUSB0,b115200,raw,echo=0 TCP-LISTEN:4600,reuseaddr,fork    # broker
    ./console.py                        # just print what the box says
    ./console.py 'fw_printenv bootargs' # type commands, print the replies

`console.py` only needs this broker; the stock shell needs knowhow, not code.
"""
import socket
import sys
import time

HOST = '127.0.0.1'
PORT = 4600


def rd(s, dur=0.6):
    out = b''
    end = time.time() + dur
    while time.time() < end:
        try:
            c = s.recv(8192)
            if not c:
                break
            out += c
        except socket.timeout:
            pass
    return out


def main():
    s = socket.create_connection((HOST, PORT))
    s.settimeout(0.2)
    if len(sys.argv) < 2:                      # passive listen
        end = time.time() + 30
        while time.time() < end:
            sys.stdout.write(rd(s).decode('utf-8', 'replace'))
            sys.stdout.flush()
        return
    rd(s, 0.6)                                 # drain
    for cmd in sys.argv[1:]:
        s.sendall(cmd.encode() + b'\r')
        time.sleep(0.5)
        sys.stdout.write(rd(s, 1.5).decode('utf-8', 'replace'))
        sys.stdout.flush()


if __name__ == '__main__':
    main()
