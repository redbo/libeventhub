"""
This is pretty normal for me:

redbo@swiftdev:~/libeventhub$ python speedtest.py 
normal read          0.182
libeventhub          3.069
tpool                31.296
"""
import os
import time

import eventlet
from eventlet import tpool, hubs

import libeventhub
import nbio


# hubs.use_hub(libeventhub)

READ_AMOUNT = (1024 ** 3)

def read_file(desc, mode):
    start = time.time()
    fd = os.open('/dev/zero', 0)
    read_amount = 0
    while read_amount < READ_AMOUNT:
        if mode == 0:
            chunk = os.read(fd, 65536)
        elif mode == 1:
            chunk = tpool.execute(os.read, fd, 65536)
        elif mode == 2:
            chunk = nbio.disk_read(fd, 65536)
        read_amount += len(chunk)
    print "%-20s %5.3f" % (desc, time.time() - start)

read_file("normal read", 0)
read_file("libeventhub", 2)
read_file("tpool", 1)

