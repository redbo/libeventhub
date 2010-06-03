"""
This is a docstring.
"""

import sys
import traceback

from eventlet.support import greenlets as greenlet
from eventlet.hubs import hub


cdef extern from "Python.h":
    void Py_INCREF(object o)
    void Py_DECREF(object o)


cdef extern from "sys/time.h":
    struct timeval:
        unsigned int tv_sec
        unsigned int tv_usec


cdef extern from "event.h":
    struct event:
        pass
    struct event_base:
        pass
    int event_add(event *ev, timeval *tv)
    int event_del(event *ev)
    int event_pending(event *ev, short, timeval *tv)
    void event_set(event *ev, int fd, short event,
                   void (*handler)(int fd, short evtype, void *arg), void *arg)
    int event_base_set(event_base *base, event *evt)
    int event_base_loop(event_base *base, int loop) nogil
    int event_base_loopbreak(event_base *base)
    int event_base_free(event_base *base)
    event_base *event_base_new()

    int EVLOOP_ONCE, EV_READ, EV_WRITE, EV_SIGNAL, EV_TIMEOUT


cdef void _event_cb(int fd, short evtype, void *arg) with gil:
    (<object>arg)()


cdef class Base:
    cdef event_base *_base
    cdef object _exc

    def __cinit__(self, *args, **kwargs):
        self._base = event_base_new()

    def __dealloc__(self):
        event_base_free(self._base)

    def dispatch(self):
        with nogil:
            event_base_loop(self._base, EVLOOP_ONCE)
        if self._exc:
            exc = self._exc
            self._exc = None
            raise exc[0], exc[1], exc[2]

    def add_event(self, callback, args=(), kwargs={}, evtype=0, fileno=-1,
                 caller=None, timeout=None):
        return Event(self, callback, args, kwargs, evtype, fileno, caller, timeout)

    def raise_error(self):
        exc = sys.exc_info()
        if any(exc):
            self._exc = exc
            event_base_loopbreak(self._base)


cdef class Event:
    cdef public object fileno, evtype
    cdef object _caller, _callback, _args, _kwargs
    cdef int _cancelled
    cdef event _ev
    cdef Base _base

    def __init__(self, Base base, callback, args=(), kwargs={}, evtype=0,
                 fileno=-1, caller=None, timeout=None):
        cdef timeval tv
        self.fileno = fileno
        self.evtype = evtype
        self._base = base
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
        event_base_set(base._base, &self._ev)
        if timeout is None:
            event_add(&self._ev, NULL)
        else:
            tv.tv_sec = <long>timeout
            tv.tv_usec = <unsigned int>((timeout - <float>tv.tv_sec) * 1000000.0)
            event_add(&self._ev, &tv)
        Py_INCREF(self)

    def __call__(self):
        if not self._cancelled:
            if not self._caller or not self._caller.dead:
                try:
                    self._callback(*self._args, **self._kwargs)
                except BaseException:
                    self._base.raise_error()
            self.cancel()

    def cancel(self):
        if not self._cancelled:
            event_del(&self._ev)
            self._cancelled = 1
            Py_DECREF(self)


class Hub(hub.BaseHub):
    def __init__(self):
        super(Hub,self).__init__()
        self._base = Base()
        self._base.add_event(self.greenlet.parent.throw, (KeyboardInterrupt,),
                evtype=EV_SIGNAL, fileno=2)

    def run(self):
        while True:
            try:
                self._base.dispatch()
            except self.SYSTEM_EXCEPTIONS:
                raise
            except greenlet.GreenletExit:
                break
            except:
                self.squelch_timer_exception(None, sys.exc_info())

    def abort(self, wait=True):
        self.schedule_call_global(0, self.greenlet.throw, greenlet.GreenletExit)
        if wait:
            assert self.greenlet is not greenlet.getcurrent(), \
                "Can't abort with wait from inside the hub's greenlet."
            self.switch()

    def _get_running(self):
        return bool(self.greenlet)

    def _set_running(self, value):
        pass

    running = property(_get_running, _set_running)

    def add(self, evtype, fileno, cb):
        evt = self._base.add_event(cb, (fileno,), evtype=evtype, fileno=fileno)
        bucket = self.listeners[evtype]
        if fileno in bucket:
            if hub.g_prevent_multiple_readers:
                evt.cancel()
                raise RuntimeError("Second simultaneous %s on fileno %s "\
                     "detected.  Unless you really know what you're doing, "\
                     "make sure that only one greenthread can %s any "\
                     "particular socket.  Consider using a pools.Pool. "\
                     "If you do know what you're doing and want to disable "\
                     "this error, call "\
                     "eventlet.debug.hub_multiple_reader_prevention(False)" % (
                     evtype, fileno, evtype))
            self.secondaries[evtype].setdefault(fileno, []).append(evt)
        else:
            bucket[fileno] = evt
        return evt

    def remove_descriptor(self, fileno):
        for lcontainer in self.listeners.itervalues():
            listener = lcontainer.pop(fileno, None)
            if listener:
                try:
                    listener.cancel()
                except self.SYSTEM_EXCEPTIONS:
                    raise
                except:
                    traceback.print_exc()

    def schedule_call_local(self, seconds, cb, *args, **kwargs):
        current = greenlet.getcurrent()
        if current is self.greenlet:
            return self.schedule_call_global(seconds, cb, *args, **kwargs)
        return self._base.add_event(cb, args, kwargs, evtype=EV_TIMEOUT,
                    caller=current, timeout=seconds)

    def schedule_call_global(self, seconds, cb, *args, **kwargs):
        return self._base.add_event(cb, args, kwargs, evtype=EV_TIMEOUT,
                    timeout=seconds)

