import sys
import traceback

from eventlet.support import greenlets
from eventlet.hubs.hub import BaseHub, READ, WRITE
import eventlet.hubs


cdef extern from "Python.h":
    void Py_INCREF(object)
    void Py_DECREF(object)

ctypedef void (*event_handler)(int fd, short evtype, void *arg)

cdef extern from 'sys/time.h':
    struct timeval:
        unsigned long tv_sec
        unsigned long tv_usec

cdef extern from "event.h":
    struct event_base:
        pass
    struct event:
        pass

    void evtimer_set(event *ev, event_handler handler, void *arg)
    int event_pending(event *ev, short, timeval *tv)
    int event_add(event *, timeval *)
    int event_del(event *)
    void event_set(event *, int, short, void (*)(int, short, void *), void *)
    int event_base_set(event_base *, event *)
    int event_base_loopbreak(event_base *)
    int event_base_free(event_base *)
    int event_base_loop(event_base *, int) nogil
    event_base *event_base_new()

    int EVLOOP_ONCE, EVLOOP_NONBLOCK
    int EV_TIMEOUT, EV_READ, EV_WRITE, EV_SIGNAL, EV_PERSIST

cdef void event_callback(int fd, short evtype, void *arg) with gil:
    (<object>arg)()

cdef class Event:
    cdef event ev
    cdef public object fileno, cb
    cdef object args, _evtype
    cdef public object seconds, hub
    cdef timeval tv

    def __init__(self, callback, arg=None, short evtype=0, fileno=-1,
                 seconds=None, hub=None):
        self.cb = callback
        self.args = arg
        self._evtype = evtype
        self.fileno = fileno
        self.seconds = seconds
        self.hub = hub
        if evtype == 0 and not fileno:
            evtimer_set(&self.ev, event_callback, <void *>self)
        else:
            event_set(&self.ev, fileno, evtype, event_callback, <void *>self)

    def __call__(self):
        try:
            if self.cb(*self.args) != None:
                if self.tv.tv_sec or self.tv.tv_usec:
                    event_add(&self.ev, &self.tv)
                else:
                    event_add(&self.ev, NULL)
        except:
            self.hub.async_exception_occurred()
        if not (self._evtype & EV_SIGNAL) and not self.pending():
            Py_DECREF(self)

    def add(self):
        if not self.pending():
            Py_INCREF(self)
        if self.seconds is not None:
            self.tv.tv_sec = <unsigned long>self.seconds
            self.tv.tv_usec = <unsigned long>((<double>self.seconds -
                        <double>self.tv.tv_sec) * 1000000.0)
            event_add(&self.ev, &self.tv)
        else:
            self.tv.tv_sec = self.tv.tv_usec = 0
            event_add(&self.ev, NULL)
        self.seconds = None

    def pending(self):
        return event_pending(&self.ev, EV_TIMEOUT | EV_SIGNAL | EV_READ | EV_WRITE, NULL)

    def cancel(self):
        if self.pending():
            event_del(&self.ev)
            Py_DECREF(self)

    @property
    def evtype(self):
        if self._evtype == EV_READ:
            return READ
        else:
            return WRITE

    def __dealloc__(self):
        self.cancel()


def _scheduled_call(evt, callback, args, kwargs, caller_greenlet=None):
    try:
        if not caller_greenlet or not caller_greenlet.dead:
            callback(*args, **kwargs)
    finally:
        evt.cancel()


cdef class EventBase:
    cdef event_base *_base

    def __cinit__(self):
        self._base = event_base_new()

    def __dealloc__(self):
        event_base_free(self._base)

    def event_loop(self):
        cdef int response
        with nogil:
            response = event_base_loop(self._base, EVLOOP_ONCE)
        return response

    def abort_loop(self):
        event_base_loopbreak(self._base)

    def new_event(self, callback, arg=None, short evtype=0, handle=-1,
                 seconds=None):
        evt = Event(callback, arg, evtype, handle, seconds, self)
        event_base_set(self._base, &evt.ev)
        return evt


class Hub(EventBase, BaseHub):

    def __init__(self):
        super(Hub, self).__init__()
        self._event_exc = None
        self.signal_exc_info = None
        self.signal(2,
            lambda signalnum, frame: self.greenlet.parent.throw(KeyboardInterrupt))

    def run(self):
        while True:
            try:
                result = self.event_loop()
                if self._event_exc is not None:
                    t = self._event_exc
                    self._event_exc = None
                    raise t[0], t[1], t[2]

                if result != 0:
                    return result
            except greenlets.GreenletExit:
                break
            except self.SYSTEM_EXCEPTIONS:
                raise
            except:
                if self.signal_exc_info is not None:
                    self.schedule_call_global(
                        0, greenlets.getcurrent().parent.throw, *self.signal_exc_info)
                    self.signal_exc_info = None
                else:
                    self.squelch_timer_exception(None, sys.exc_info())

    def abort(self, wait=True):
        self.schedule_call_global(0, self.greenlet.throw, greenlets.GreenletExit)
        if wait:
            assert self.greenlet is not greenlets.getcurrent(), \
                        "Can't abort with wait from inside the hub's greenlet."
            self.switch()

    def _getrunning(self):
        return bool(self.greenlet)

    def _setrunning(self, value):
        pass  # exists for compatibility with BaseHub
    running = property(_getrunning, _setrunning)

    def add(self, evtype, fileno, cb):
        if evtype is READ:
            evt = self.new_event(cb, (fileno,), EV_READ, fileno)
            evt.add()
        elif evtype is WRITE:
            evt = self.new_event(cb, (fileno,), EV_WRITE, fileno)
            evt.add()
        # Events double as FdListener objects
        self.listeners[evtype][fileno] = evt
        return evt

    def remove(self, listener):
        listener.cancel()

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

    def signal(self, signalnum, handler):
        def wrapper():
            try:
                handler(signalnum, None)
            except:
                self.signal_exc_info = sys.exc_info()
                self.abort_loop()
        evt = self.new_event(wrapper, (), EV_SIGNAL | EV_PERSIST, signalnum)
        evt.add()
        return evt

    def schedule_call_local(self, seconds, cb, *args, **kwargs):
        current = greenlets.getcurrent()
        if current is self.greenlet:
            return self.schedule_call_global(seconds, cb, *args, **kwargs)
        args = [None, cb, args, kwargs, current]
        evt = self.new_event(_scheduled_call, args, seconds=seconds)
        args[0] = evt
        evt.add()
        return evt

    schedule_call = schedule_call_local

    def schedule_call_global(self, seconds, cb, *args, **kwargs):
        args = [None, cb, args, kwargs]
        evt = self.new_event(_scheduled_call, args, seconds=seconds)
        args[0] = evt
        evt.add()
        return evt

    def async_exception_occurred(self):
        self._event_exc = sys.exc_info()

def use():
    eventlet.hubs.use_hub(Hub)
