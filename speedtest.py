import os
import time

def read_file():
    start = time.time()
    fd = os.open('/dev/zero', 0)
    read_amount = 0
    while read_amount < (1024 ** 3): # 1gb
        read_amount += len(os.read(fd, 32768)) # 32kb
    print (time.time() - start), "seconds"

for x in xrange(3):
    read_file()

