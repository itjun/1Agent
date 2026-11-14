"""隔离 PTY 的交互程序，不访问用户文件或网络。"""
import os
import sys
import time
import tty

tty.setraw(0)
with open(sys.argv[1], 'a') as f:
    f.write(str(os.getpid()) + '\n')
os.write(1, b'PRIMARY_HISTORY\r\n\x1b]7;file://fixture/tmp/a%20b\x07\x1b]133;C\x07\x1b]2;pi --session test\x07')
os.write(1, b'\x1b[?1049h\x1b[2J\x1b[?2004h\x1b[?1003h\x1b[?1006h\x1b[>3u\x1b[5;7H\x1b[32mTUI_READY')
while True:
    c = os.read(0, 65536)
    if c == b'd':
        time.sleep(.3)
        os.write(1, b'\x1b[6;2HDETACHED_OUTPUT')
    elif c == b'q':
        os.write(1, b'\x1b[6n')
        response = b''
        while not response.endswith(b'R'):
            response += os.read(0, 1)
        os.write(1, b'\x1b[7;1HQUERY_REPLY:' + response.hex().encode())
    elif c == b'p':
        os.write(1, b'\x1b[?1049l\r\nPRIMARY_RETURN')
    elif c == b'f':
        os.write(1, b'\x1b[8;1H\xe4\xb8')
        time.sleep(.7)
        os.write(1, b'\xadUTF8_COMPLETE')
    elif c == b'e':
        os.write(1, b'\x1b[9;')
        time.sleep(.7)
        os.write(1, b'1HESCAPE_COMPLETE')
    elif c == b'x':
        sys.exit(7)
    elif c == b's':
        os.write(1, b'\x1b]133;D;0\x07\x1b]133;A\x07')
    elif c == b'w':
        import struct, fcntl, termios
        rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
        os.write(1, f'\x1b[10;1HSIZE:{cols}x{rows}'.encode())
    elif c == b'l':
        os.write(1, b'\x1b[12;1HLARGE_READY')
        received = b''
        while len(received) < 2 * 1024 * 1024 + 123:
            received += os.read(0, min(65536, 2 * 1024 * 1024 + 123 - len(received)))
        assert received == b'z' * (2 * 1024 * 1024 + 123)
        os.write(1, b'\x1b[13;1HLARGE_INPUT_COMPLETE')
    elif c == b'b':
        os.write(1, b'\x1b[2J' + b'B' * 3000000 + b'BURST_DONE')
    else:
        os.write(1, b'\x1b[11;1HINPUT:' + c)
