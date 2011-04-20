import sys
import traceback

from eventlet.support import greenlets as greenlet
from eventlet.hubs import hub


cdef extern from 'Python.h':
    void Py_INCREF(object o)
    void Py_DECREF(object o)


cdef extern from 'sys/time.h':
    ctypedef long time_t
    ctypedef long suseconds_t
    struct timeval:
        time_t tv_sec
        suseconds_t tv_usec


cdef extern from 'event.h':
    struct event:
        pass
    struct event_base:
        pass
    int event_add(event *ev, timeval *tv)
    int event_del(event *ev)
    void event_set(event *ev, int fd, short event,
                   void (*handler)(int fd, short evtype, void *arg), void *arg)
    int event_base_set(event_base *base, event *evt)
    int event_base_loop(event_base *base, int loop) nogil
    int event_base_loopbreak(event_base *base)
    int event_base_free(event_base *base)
    event_base *event_base_new()

    int EV_READ, EV_WRITE, EV_SIGNAL, EV_TIMEOUT


cdef void _event_cb(int fd, short evtype, void *arg) with gil:
    (<Event>arg).callback()


cdef class Base:
    cdef event_base *_base
    cdef object _exc

    def __cinit__(self, *args, **kwargs):
        self._base = event_base_new()

    def __dealloc__(self):
        event_base_free(self._base)

    cdef add_event(self, event *ev):
        return event_base_set(self._base, ev)

    cdef loop(self):
        with nogil:
            event_base_loop(self._base, 0)

    cdef loopbreak(self):
        event_base_loopbreak(self._base)


cdef class Event:
    cdef public int fileno
    cdef public object evtype
    cdef object _caller, _callback, _args, _kwargs, _hub
    cdef int _cancelled
    cdef event _ev

    def __init__(self, hub, callback, args, kwargs, evtype, int fileno,
                 caller, float timeout):
        cdef timeval tv, *ptv = NULL
        self.fileno = fileno
        self.evtype = evtype
        self._hub = hub
        self._callback = callback
        self._args = args
        self._kwargs = kwargs
        self._caller = caller
        self._cancelled = 0
        if evtype is hub.WRITE:
            evtype = EV_WRITE
        elif evtype is hub.READ:
            evtype = EV_READ
        event_set(&self._ev, fileno, evtype, _event_cb, <void *>self)
        (<Base>hub._base).add_event(&self._ev)
        if timeout >= 0.0:
            tv.tv_sec = <time_t>timeout
            tv.tv_usec = <suseconds_t>((timeout - <time_t>timeout) * 1000000.0)
            ptv = &tv
        if event_add(&self._ev, ptv):
            raise RuntimeError("Unable to add event %s on fileno %d" % (evtype, fileno))
        Py_INCREF(self) # libevent is now holding a reference to this object
        (<Base>hub._base).loopbreak()

    cdef callback(self):
        if not self._cancelled:
            if not self._caller or not self._caller.dead:
                try:
                    self._callback(*self._args, **self._kwargs)
                except BaseException:
                    self._hub.raise_error()
            self.cancel()

    cpdef cancel(self):
        if not self._cancelled:
            self._cancelled = 1
            event_del(&self._ev)
            Py_DECREF(self)


class Hub(hub.BaseHub):
    def __init__(self):
        super(Hub,self).__init__()
        self._base = Base()
        self._kbint = Event(self, self.greenlet.parent.throw,
                (KeyboardInterrupt,), {}, EV_SIGNAL, 2, None, -1.0)
        self._exc = None

    def run(self):
        while True:
            (<Base>self._base).loop()
            if self._exc:
                exc = self._exc
                self._exc = None
                if isinstance(exc[0], self.SYSTEM_EXCEPTIONS):
                    raise tuple(exc)
                elif isinstance(exc[0], greenlet.GreenletExit):
                    break
                else:
                    self.squelch_timer_exception(None, exc)

    def raise_error(self):
        self._exc = sys.exc_info()
        (<Base>self._base).loopbreak()

    def abort(self, wait=True):
        self.schedule_call_global(0, self.greenlet.throw, greenlet.GreenletExit)
        if wait:
            assert self.greenlet is not greenlet.getcurrent(), \
                "Can't abort with wait from inside the hub's greenlet."
            self.switch()
        (<Base>self._base).loopbreak()

    def add(self, evtype, fileno, cb):
        return Event(self, cb, (fileno,), {}, evtype, fileno, None, -1.0)

    def schedule_call_local(self, seconds, cb, *args, **kwargs):
        current = greenlet.getcurrent()
        if current is self.greenlet:
            current = None  # actually schedule the call globally
        return Event(self, cb, args, kwargs, EV_TIMEOUT, -1, current, seconds)

    def schedule_call_global(self, seconds, cb, *args, **kwargs):
        return Event(self, cb, args, kwargs, EV_TIMEOUT, -1, None, seconds)

