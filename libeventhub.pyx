import sys
import traceback

from eventlet.support import greenlets as greenlet
from eventlet.hubs import hub


cdef extern from 'Python.h':
    void Py_INCREF(object)
    void Py_DECREF(object)


cdef extern from 'sys/time.h':
    ctypedef long time_t
    ctypedef long suseconds_t
    struct timeval:
        time_t tv_sec
        suseconds_t tv_usec


cdef extern from 'event.h':
    struct event:
        pass # this is okay as an opaque pointer
    struct event_base:
        pass # this is okay as an opaque pointer
    int event_add(event *, timeval *)
    int event_del(event *)
    void event_set(event *, int, short, void (*)(int, short, void *), void *)
    int event_base_set(event_base *, event *)
    int event_base_loopbreak(event_base *)
    int event_base_free(event_base *)
    int event_base_loop(event_base *, int) nogil
    event_base *event_base_new()

    int EV_READ, EV_WRITE, EV_SIGNAL, EV_TIMEOUT
    int EVLOOP_ONCE


cdef void _event_cb(int fd, short evtype, void *arg) with gil:
    print "callbacking"
    (<Event>arg).callback()
    print "/callbacking"


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
            event_base_loop(self._base, EVLOOP_ONCE)

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
        if evtype is hub.WRITE:
            evtype = EV_WRITE
        elif evtype is hub.READ:
            evtype = EV_READ
        event_set(&self._ev, fileno, evtype, _event_cb, <void *>self)
        if timeout >= 0.0:
            tv.tv_sec = <time_t>timeout
            tv.tv_usec = <suseconds_t>((timeout - <time_t>timeout) * 1000000.0)
            ptv = &tv
        if not (<Base>hub._base).add_event(&self._ev):
            self._cancelled = 0
            Py_INCREF(self) # libevent base is now holding a pointer to me
        else:
            self._cancelled = 1
            raise RuntimeError("Unable to add event to base.")
        if event_add(&self._ev, ptv):
            self.cancel()
            raise RuntimeError("Unable to add event %s on fileno %d" % (evtype, fileno))
        (<Base>hub._base).loopbreak()

    cdef callback(self):
        if not self._cancelled:
            if not self._caller or not self._caller.dead:
                try:
                    self._callback(*self._args, **self._kwargs)
                except BaseException:
                    self._hub.raise_error()
            self.cancel()

    def cancel(self):
        if not self._cancelled:
            self._cancelled = 1
            event_del(&self._ev)
            Py_DECREF(self) # libevent should no longer be holding a reference

    def __hash__(self):
        return <long>&self._ev


class Hub(hub.BaseHub):
    def __init__(self):
        super(Hub,self).__init__()
        self._base = Base()
        self._kbint = Event(self, self.greenlet.parent.throw,
                (KeyboardInterrupt,), {}, EV_SIGNAL, 2, None, -1.0)
        self._exc = None

    def run(self):
        x = self.greenlet # wtfbbq
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
                "Can't abort with wait from inside the hub's greenlet"
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

    def remove(self, listener):
        "This hub doesn't track listeners"
        pass

    def _implement_later(self, *args, **kwargs):
        raise NotImplementedError("I haven't implemented this method yet")
    block_detect_pre = block_detect_post = timer_canceled = _implement_later

    def _unimplemented(self, *args, **kwargs):
        raise NotImplementedError("This method didn't make sense for this hub")
    remove_descriptor = squelch_exception = wait = sleep_until = \
        default_sleep = add_timer = prepare_timers = fire_timers = \
        get_readers = get_writers = get_timers_count = \
        set_debug_listeners = _unimplemented

