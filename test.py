from eventlet import hubs, wsgi, listen, tpool, Timeout, sleep
from eventlet.green.urllib2 import urlopen

import libeventhub


def read_somethingelse():
    return urlopen('http://127.0.0.1:8090/somethingelse').read()

def hello_world(env, start_response):
    if env['PATH_INFO'] == '/':
        with Timeout(300):
            content = tpool.execute(read_somethingelse)
            sleep(0.01)
    else:
        content = 'oh hai'
    start_response('200 OK', [('Content-Type', 'text/plain'),
                              ('Content-Length', str(len(content)))])
    return [content]


hubs.use_hub(libeventhub)
wsgi.server(listen(('', 8090)), hello_world)

