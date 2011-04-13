import sys
import traceback
import os

from eventlet.hubs import trampoline


THREAD_COUNT = 32


cdef extern from 'fcntl.h':
    int posix_fadvise(int fd, long offset, long len, int advice) nogil
    int posix_fallocate(int fd, long offset, long len) nogil
    int POSIX_FADV_DONTNEED


cdef extern from 'unistd.h':
    int fsync(int fd) nogil
    int fdatasync(int fd) nogil
    long read(int fd, void *buf, long count) nogil
    long write(int fd, void *buf, long count) nogil
    int close(int fd) nogil


cdef extern from 'pthread.h':
    ctypedef long pthread_mutex_t
    void pthread_mutex_init(pthread_mutex_t *, void *arg) nogil
    void pthread_mutex_lock(pthread_mutex_t *) nogil
    void pthread_mutex_unlock(pthread_mutex_t *) nogil
    ctypedef long pthread_t
    ctypedef long pthread_attr_t
    int pthread_create(pthread_t *thread, pthread_attr_t *attr,
                void *(*start_routine)(void*), void *arg) nogil
    int pthread_join(pthread_t thread, void **value_ptr) nogil
    int pthread_attr_init(pthread_attr_t *attr)
    int pthread_attr_setdetachstate(pthread_attr_t *attr, int)
    int PTHREAD_CREATE_DETACHED


cdef struct fd_operation:
    int fd
    int op
    long length
    long offset
    char *buf
    long response
    int response_writer


cdef int queue_fd_reader, queue_fd_writer
cdef pthread_mutex_t reader_mutex
cdef pthread_attr_t reader_mutex_attr


cdef _launch_thread():
    cdef pthread_t io_thread
    cdef pthread_attr_t attr
    pthread_attr_init(&attr)
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED)
    pthread_create(&io_thread, NULL, &fd_operate, NULL)


def _init():
    global queue_fd_reader, queue_fd_writer
    queue_fd_reader, queue_fd_writer = os.pipe()
    pthread_mutex_init(&reader_mutex, NULL)
    for x in xrange(THREAD_COUNT):
        _launch_thread()


cdef void *fd_operate(void *arg) nogil:
    """
    pthread target that performs file operations.
    No python allowed, so we never have to acquire the GIL.
    """
    cdef fd_operation *op
    while 1:
        pthread_mutex_lock(&reader_mutex)
        read(queue_fd_reader, &op, sizeof(fd_operation *))
        pthread_mutex_unlock(&reader_mutex)
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
        write(op.response_writer, "!", 1)


cdef _file_op(int opcode, int fd, char *buf=NULL, long length=0, long offset=0):
    cdef fd_operation op, *opp
    opp = &op
    cdef pthread_t thrd
    response_reader, op.response_writer = os.pipe()
    op.fd = fd
    op.op = opcode
    op.buf = buf
    op.length = length
    op.offset = offset
    write(queue_fd_writer, &opp, sizeof(fd_operation*))
    trampoline(response_reader, read=True)
    close(response_reader)
    close(op.response_writer)
    return op.response

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


_init()

