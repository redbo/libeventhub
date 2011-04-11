import sys
import traceback
import os

from eventlet.hubs import trampoline


cdef extern from 'fcntl.h':
    int posix_fadvise(int fd, long offset, long len, int advice)
    int posix_fallocate(int fd, long offset, long len)
    int POSIX_FADV_DONTNEED


cdef extern from 'unistd.h':
    int fsync(int fd)
    int fdatasync(int fd)
    long read(int fd, void *buf, long count)
    long write(int fd, void *buf, long count)
    int close(int fd)


cdef extern from 'pthread.h':
    ctypedef long pthread_t
    ctypedef long pthread_attr_t
    int pthread_create(pthread_t *thread, pthread_attr_t *attr,
                void *(*start_routine)(void*), void *arg)


cdef struct file_operation:
    int fd
    int op
    long length
    long offset
    char *buf
    long response
    int response_writer


cdef void *fd_operate(file_operation *op):
    if op.op == 1:
        op.response = write(op.fd, op.buf, op.length)
    elif op.op == 2:
        op.response = read(op.fd, op.buf, op.length)
    elif op.op == 3:
        op.response = fsync(op.fd)
    elif op.op == 4:
        op.response = fdatasync(op.fd)
    elif op.op == 5:
        op.response = posix_fallocate(op.fd, 0, op.length)
    elif op.op == 6:
        op.response = posix_fadvise(op.fd, op.offset, op.length,
                POSIX_FADV_DONTNEED)
    cdef long _write_response = write(op.response_writer, "!", 1)
    return op


cdef _file_op(int file_op, int fd, char *buf=NULL, long length=0, long offset=0):
    cdef file_operation op
    cdef pthread_t thrd
    response_reader, response_writer = os.pipe()
    try:
        op.response_writer = response_writer
        op.fd = fd
        op.op = file_op
        op.buf = buf
        op.length = length
        op.offset = offset
        pthread_create(&thrd, NULL, <void *(*)(void*)>&fd_operate, <void *>&op)
        trampoline(response_reader, read=True)
        return op.response
    finally:
        close(response_reader)
        close(response_writer)

# TODO raise errors

def disk_write(fd, buf):
    return _file_op(1, fd, buf, len(buf))


def disk_read(fd, length):
    cdef char read_buf[65536]
    if length > sizeof(read_buf):
        length = sizeof(read_buf)
    length = _file_op(2, fd, read_buf, length)
    return read_buf[:length]


def disk_fsync(fd):
    return _file_op(3, fd)


def disk_fdatasync(fd):
    return _file_op(4, fd)


def disk_fallocate(fd, length):
    return _file_op(5, fd, NULL, length)


def disk_drop_cache(fd, offset, length):
    return _file_op(6, fd, NULL, length, offset)

__all__ = ['disk_write', 'disk_read', 'disk_fsync', 'disk_fdatasync',
           'disk_fallocate', 'disk_drop_cache']

