#
# pyliblo - Python bindings for the liblo OSC library
#
# Copyright (C) 2007-2010  Dominic Sacré  <dominic.sacre@gmx.de>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation; either version 2.1 of the
# License, or (at your option) any later version.
#

__version__ = '0.10.0'


from cpython cimport PY_VERSION_HEX
cdef extern from 'Python.h':
    void PyEval_InitThreads()

from libc.stdlib cimport malloc, free
cdef extern from 'math.h':
    double modf(double x, double *iptr)

from liblo cimport *

import inspect as _inspect
import weakref as _weakref


class _weakref_method:
    def __init__(self, f):
        if PY_VERSION_HEX >= 0x03000000:
            self.f = f.__func__
            self.c = _weakref.ref(f.__self__)
        else:
            self.f = f.im_func
            self.c = _weakref.ref(f.im_self)
    def __call__(self):
        return self.f.__get__(self.c(), self.c().__class__)


cdef str _decode(s):
    # convert to standard string type, depending on python version
    if PY_VERSION_HEX >= 0x03000000 and isinstance(s, bytes):
        return s.decode()
    else:
        return s

cdef bytes _encode(s):
    # convert unicode to bytestring
    if isinstance(s, unicode):
        return s.encode()
    else:
        return s


cdef class _ServerBase
cdef class Address
cdef class Message
cdef class Bundle


UDP  = LO_UDP
TCP  = LO_TCP
UNIX = LO_UNIX


################################################################################################
#  timetag
################################################################################################

cdef lo_timetag _double_to_timetag(double f):
    cdef lo_timetag tt
    cdef double intr, frac
    frac = modf(f, &intr)
    tt.sec = <uint32_t>intr
    tt.frac = <uint32_t>(frac * 4294967296.0)
    return tt

cdef double _timetag_to_double(lo_timetag tt):
    return <double>tt.sec + (<double>(tt.frac) / 4294967296.0)

def time():
    """
    time()

    Returns the current time as a float in OSC format, that is, the number of seconds since the epoch (January 1, 1900).
    """
    cdef lo_timetag tt
    lo_timetag_now(&tt)
    return _timetag_to_double(tt)


################################################################################################
#  send
################################################################################################

def _send(target, _ServerBase src, *msg):
    cdef lo_server serv
    cdef Address addr
    cdef int r

    if isinstance(target, Address):
        addr = target
    elif isinstance(target, tuple):
        # unpack tuple
        addr = Address(*target)
    else:
        addr = Address(target)

    if not isinstance(msg[0], (Message, Bundle)):
        # treat arguments as one single message
        msg = [Message(*msg)]

    if src:
        serv = src._serv
    else:
        serv = NULL

    for m in msg:
        if isinstance(m, Message):
            r = lo_send_message_from(addr._addr, serv, (<Message>m)._path, (<Message>m)._msg)
        else:
            r = lo_send_bundle_from(addr._addr, serv, (<Bundle>m)._bundle)

        if r == -1:
            raise IOError("sending failed: %s" % <char*>lo_address_errstr(addr._addr))


def send(target, *msg):
    """
    send(target, message)
    send(target, bundle)
    send(target, path[, arg, ...])

    Sends a message or bundle to the the given target, without requiring a server.
    target may be an Address object, a port number, a (hostname, port) tuple, or a URL.
    Exceptions: AddressError
    """
    _send(target, None, *msg)


################################################################################################
#  Server
################################################################################################

class ServerError(Exception):
    def __init__(self, num, msg, where):
        self.num = num
        self.msg = msg
        self.where = where
    def __str__(self):
        s = "server error %d" % self.num
        if self.where: s += " in %s" % self.where
        s += ": %s" % self.msg
        return s


class _CallbackData:
    def __init__(self, func, data):
        self.func = func
        self.data = data


cdef int _callback(const_char *path, const_char *types, lo_arg **argv, int argc, lo_message msg, void *cb_data) with gil:
    cdef unsigned char *ptr
    cdef uint32_t size, j
    cdef char *url
    args = []

    for i from 0 <= i < argc:
        t = chr(types[i])
        if   t == 'i': v = argv[i].i
        elif t == 'h': v = argv[i].h
        elif t == 'f': v = argv[i].f
        elif t == 'd': v = argv[i].d
        elif t == 'c': v = chr(argv[i].c)
        elif t == 's': v = _decode(&argv[i].s)
        elif t == 'S': v = _decode(&argv[i].s)
        elif t == 'T': v = True
        elif t == 'F': v = False
        elif t == 'N': v = None
        elif t == 'I': v = float('inf')
        elif t == 'm': v = (argv[i].m[0], argv[i].m[1], argv[i].m[2], argv[i].m[3])
        elif t == 't': v = _timetag_to_double(argv[i].t)
        elif t == 'b':
            if PY_VERSION_HEX >= 0x03000000:
                v = bytes(<unsigned char*>lo_blob_dataptr(argv[i]))
            else:
                # convert binary data to python list
                v = []
                ptr = <unsigned char*>lo_blob_dataptr(argv[i])
                size = lo_blob_datasize(argv[i])
                for j from 0 <= j < size:
                    v.append(ptr[j])
        else:
            v = None  # unhandled data type

        args.append(v)

    url = lo_address_get_url(lo_message_get_source(msg))
    src = Address(url)
    free(url)

    cb = <object>cb_data
    if isinstance(cb.func, _weakref_method):
        func = cb.func()
    else:
        func = cb.func
    func_args = (_decode(<char*>path), args, _decode(<char*>types), src, cb.data)

    # call function
    if _inspect.getargspec(func)[1] == None:
        # determine number of arguments to call the function with
        n = len(_inspect.getargspec(func)[0])
        if _inspect.ismethod(func): n = n - 1  # self doesn't count
        r = func(*func_args[0:n])
    else:
        # function has argument list, pass all arguments
        r = func(*func_args)

    if r == None:
        return 0
    else:
        return r


cdef void _err_handler(int num, const_char *msg, const_char *where) with gil:
    # can't raise exception in cdef callback function, so use a global variable instead
    global __exception
    __exception = ServerError(num, <char*>msg, None)
    if where: __exception.where = <char*>where


# decorator to register callbacks

class make_method:
    """
    @make_method(path, typespec[, user_data])

    Decorator that basically serves the same purpose as add_method(). Decorators require Python 2.4 or later.
    Note that @make_method is defined at module scope, and not a member of class Server.
    """
    # counter to keep track of the order in which the callback functions where defined
    _counter = 0

    def __init__(self, path, types, user_data=None):
        self.spec = (make_method._counter, path, types, user_data)
        make_method._counter += 1

    def __call__(self, f):
        # we can't access the Server object here, because at the time the decorator is run it
        # doesn't even exist yet. so we store the path/typespec in the function object instead...
        if not hasattr(f, '_method_spec'):
            f._method_spec = []
        f._method_spec.append(self.spec)
        return f


# common base class for both Server and ServerThread

cdef class _ServerBase:
    cdef lo_server _serv
    cdef list _keep_refs

    def __init__(self, **kwargs):
        self._keep_refs = []

        if 'reg_methods' not in kwargs or kwargs['reg_methods']:
            self.register_methods()

    def register_methods(self, obj=None):
        """
        register_methods([obj])

        Calls add_method() for all methods of obj decorated with @make_method. obj defaults to the Server object itself.
        This function is called automatically by the Server's init function, unless its reg_methods parameter is False.
        """
        if obj == None:
            obj = self
        # find and register methods that were defined using decorators
        methods = []
        for m in _inspect.getmembers(obj):
            if hasattr(m[1], '_method_spec'):
                for s in m[1]._method_spec:
                    methods.append((s, m[1]))
        # sort by counter (first element in each tuple)
        methods.sort()
        for e in methods:
            self.add_method(e[0][1], e[0][2], e[1], e[0][3])

    def get_url(self):
        cdef char *tmp
        cdef object r
        tmp = lo_server_get_url(self._serv)
        r = tmp
        free(tmp)
        return _decode(r)

    def get_port(self):
        return lo_server_get_port(self._serv)

    def get_protocol(self):
        return lo_server_get_protocol(self._serv)

    def fileno(self):
        """
        fileno()

        Returns the file descriptor of the server socket, or -1 if not supported by the underlying server protocol.
        """
        return lo_server_get_socket_fd(self._serv)

    def add_method(self, path, typespec, func, user_data=None):
        """
        add_method(path, typespec, callback_func[, user_data])

        Registers a callback function for OSC messages with matching path and argument types.
        For both path and typespec, None may be used as a wildcard.
        The optional user_data will be passed on to the callback function. callback_func may be a global
        function or a class method, pyliblo will know what to do either way.
        """
        cdef char *p
        cdef char *t

        if isinstance(path, (bytes, unicode)):
            s = _encode(path)
            p = s
        elif path == None:
            p = NULL
        else:
            raise TypeError("path must be a string or None")

        if isinstance(typespec, (bytes, unicode)):
            s2 = _encode(typespec)
            t = s2
        elif typespec == None:
            t = NULL
        else:
            raise TypeError("typespec must be a string or None")

        # use a weak reference if func is a method, to avoid circular references in
        # cases where func is a method an object that also has a reference to the server
        # (e.g. when deriving from the Server class)
        if _inspect.ismethod(func):
            func = _weakref_method(func)

        cb = _CallbackData(func, user_data)
        self._keep_refs.append(cb)
        lo_server_add_method(self._serv, p, t, _callback, <void*>cb)

    def send(self, target, *msg):
        """
        send(target, message)
        send(target, bundle)
        send(target, path[, arg, ...])

        Sends a message or bundle from this server to the the given target.
        target may be an Address object, a port number, a (hostname, port) tuple, or a URL.
        Exceptions: AddressError
        """
        _send(target, self, *msg)

    property url:
        """
        The server's URL.
        """
        def __get__(self):
            return self.get_url()

    property port:
        """
        The server's port number.
        """
        def __get__(self):
            return self.get_port()

    property protocol:
        """
        The server's protocol (one of the constants UDP, TCP, UNIX).
        """
        def __get__(self):
            return self.get_protocol()


cdef class Server(_ServerBase):
    """
    Server([port[, proto[, **kwargs]]])

    Creates a new Server object, which can receive OSC messages.
    port may be a decimal port number or a UNIX socket path. If omitted, an arbitrary free UDP port will be used.
    proto can be one of the constants UDP, TCP, UNIX.
    Optional keyword arguments:
    reg_methods: False if you don't want the init function to automatically register callbacks defined with the @make_method decorator.
    Exceptions: ServerError
    """
    def __init__(self, port=None, proto=LO_UDP, **kwargs):
        cdef char *cs

        if port != None:
            p = _encode(str(port));
            cs = p
        else:
            cs = NULL

        global __exception
        __exception = None
        self._serv = lo_server_new_with_proto(cs, proto, _err_handler)
        if __exception:
            raise __exception

        _ServerBase.__init__(self, **kwargs)

    def __dealloc__(self):
        self.free()

    def free(self):
        """
        free()

        Frees the underlying server object and closes its port. Note that this will also happen automatically when the server is garbage-collected.
        """
        if self._serv:
            lo_server_free(self._serv)
            self._serv = NULL

    def recv(self, timeout=None):
        """
        recv([timeout])

        Receives and dispatches one OSC message. Blocking by default, unless timeout (in ms) is specified.
        timeout may be 0, in which case recv() returns immediately. Returns True if a message was received, False otherwise. 
        """
        cdef int t, r
        if timeout != None:
            t = timeout
            with nogil:
                r = lo_server_recv_noblock(self._serv, t)
            return r and True or False
        else:
            with nogil:
                lo_server_recv(self._serv)
            return True


cdef class ServerThread(_ServerBase):
    """
    ServerThread([port[, proto[, **kwargs]]])

    Creates a new ServerThread object, which can receive OSC messages.  Unlike Server, ServerThread uses its own thread
    which runs in the background to dispatch messages.  Note that callback methods will not be run in the main Python thread!
    port may be a decimal port number or a UNIX socket path. If omitted, an arbitrary free UDP port will be used.
    proto can be one of the constants UDP, TCP, UNIX.
    Optional keyword arguments:
    reg_methods: False if you don't want the init function to automatically register callbacks defined with the @make_method decorator.
    Exceptions: ServerError
    """
    cdef lo_server_thread _thread

    def __init__(self, port=None, proto=LO_UDP, **kwargs):
        cdef char *cs

        if port != None:
            p = _encode(str(port));
            cs = p
        else:
            cs = NULL

        # make sure python can handle threading
        PyEval_InitThreads()

        global __exception
        __exception = None
        self._thread = lo_server_thread_new_with_proto(cs, proto, _err_handler)
        if __exception:
            raise __exception
        self._serv = lo_server_thread_get_server(self._thread)

        _ServerBase.__init__(self, **kwargs)

    def __dealloc__(self):
        self.free()

    def free(self):
        """
        free()

        Frees the underlying server object and closes its port. Note that this will also happen automatically when the server is garbage-collected.
        """
        if self._thread:
            lo_server_thread_free(self._thread)
            self._thread = NULL
            self._serv = NULL

    def start(self):
        """
        start()

        Starts the server thread, liblo will now start to dispatch any messages it receives.
        """
        lo_server_thread_start(self._thread)

    def stop(self):
        """
        stop()

        Stops the server thread.
        """
        lo_server_thread_stop(self._thread)


################################################################################################
#  Address
################################################################################################

class AddressError(Exception):
    def __init__(self, msg):
        self.msg = msg
    def __str__(self):
        return "address error: %s" % self.msg


cdef class Address:
    """
    Address(hostname, port[, proto])
    Address(port)
    Address(url)

    Creates a new Address object from the given hostname/port or URL.
    proto can be one of the constants UDP, TCP, UNIX.
    Exceptions: AddressError
    """
    cdef lo_address _addr

    def __init__(self, addr, addr2=None, proto=LO_UDP):
        if addr2:
            # Address(host, port[, proto])
            s = _encode(addr)
            s2 = _encode(str(addr2))
            self._addr = lo_address_new_with_proto(proto, s, s2)
            if not self._addr:
                raise AddressError("invalid protocol")
        elif isinstance(addr, int) or (isinstance(addr, str) and addr.isdigit()):
            # Address(port)
            s = str(addr).encode()
            self._addr = lo_address_new(NULL, s)
        else:
            # Address(url)
            s = _encode(addr)
            self._addr = lo_address_new_from_url(s)
            # lo_address_errno() is of no use if self._addr == NULL
            if not self._addr:
                raise AddressError("invalid URL '%s'" % str(addr))

    def __dealloc__(self):
        lo_address_free(self._addr)

    def get_url(self):
        cdef char *tmp
        cdef object r
        tmp = lo_address_get_url(self._addr)
        r = tmp
        free(tmp)
        return _decode(r)

    def get_hostname(self):
        return _decode(lo_address_get_hostname(self._addr))

    def get_port(self):
        cdef bytes s = lo_address_get_port(self._addr)
        if s.isdigit():
            return int(s)
        else:
            return _decode(s)

    def get_protocol(self):
        return lo_address_get_protocol(self._addr)

    property url:
        """
        The address' URL.
        """
        def __get__(self):
            return self.get_url()

    property hostname:
        """
        The address' hostname.
        """
        def __get__(self):
            return self.get_hostname()

    property port:
        """
        The address' port number.
        """
        def __get__(self):
            return self.get_port()

    property protocol:
        """
        The address' protocol (one of the constants UDP, TCP, UNIX).
        """
        def __get__(self):
            return self.get_protocol()


################################################################################################
#  Message
################################################################################################

cdef class _Blob:
    cdef lo_blob _blob

    def __init__(self, arr):
        # arr can by any sequence type
        cdef unsigned char *p
        cdef uint32_t size, i
        size = len(arr)
        if size < 1:
            raise ValueError("blob is empty")
        # copy each element of arr to a C array
        p = <unsigned char*>malloc(size)
        try:
            if isinstance(arr[0], (str, unicode)):
                # use ord() if arr is a string (but not bytes)
                for i from 0 <= i < size:
                    p[i] = ord(arr[i])
            else:
                for i from 0 <= i < size:
                    p[i] = arr[i]
            # build blob
            self._blob = lo_blob_new(size, p)
        finally:
            free(p)

    def __dealloc__(self):
        lo_blob_free(self._blob)


cdef class Message:
    """
    Message(path[, arg, ...])

    Creates a new Message object.
    """
    cdef bytes _path
    cdef lo_message _msg
    cdef list _keep_refs

    def __init__(self, path, *args):
        self._keep_refs = []
        # encode path to bytestring if necessary
        self._path = _encode(path)
        self._msg = lo_message_new()

        self.add(*args)

    def __dealloc__(self):
        lo_message_free(self._msg)

    def add(self, *args):
        """
        add(arg[, ...])

        Appends the given argument(s) to the message.
        """
        for arg in args:
            if isinstance(arg, tuple) and len(arg) <= 2 and isinstance(arg[0], (bytes, unicode)) and len(arg[0]) == 1:
                # type explicitly specified
                if len(arg) == 2:
                    self._add(arg[0], arg[1])
                else:
                    self._add(arg[0], None)
            else:
                # detect type automatically
                self._add_auto(arg)

    def _add(self, t, v):
        cdef uint8_t midi[4]

        # accept both bytes and unicode as type specifier
        t = _decode(t)

        if t == 'i':
            lo_message_add_int32(self._msg, int(v))
        elif t == 'h':
            lo_message_add_int64(self._msg, long(v))
        elif t == 'f':
            lo_message_add_float(self._msg, float(v))
        elif t == 'd':
            lo_message_add_double(self._msg, float(v))
        elif t == 'c':
            lo_message_add_char(self._msg, ord(v))
        elif t == 's':
            s = _encode(v)
            lo_message_add_string(self._msg, s)
        elif t == 'S':
            s = _encode(v)
            lo_message_add_symbol(self._msg, s)
        elif t == 'T':
            lo_message_add_true(self._msg)
        elif t == 'F':
            lo_message_add_false(self._msg)
        elif t == 'N':
            lo_message_add_nil(self._msg)
        elif t == 'I':
            lo_message_add_infinitum(self._msg)
        elif t == 'm':
            for n from 0 <= n < 4:
                midi[n] = v[n]
            lo_message_add_midi(self._msg, midi)
        elif t == 't':
            lo_message_add_timetag(self._msg, _double_to_timetag(v))
        elif t == 'b':
            b = _Blob(v)
            # make sure the blob is not deleted as long as this message exists
            self._keep_refs.append(b)
            lo_message_add_blob(self._msg, (<_Blob>b)._blob)
        else:
            raise TypeError("unknown OSC data type '%s'" % str(t))

    def _add_auto(self, arg):
        # bool is a subclass of int, so check those first
        if arg is True:
            self._add('T', None)
        elif arg is False:
            self._add('F', None)
        elif isinstance(arg, int):
            self._add('i', arg)
        elif isinstance(arg, long):
            self._add('h', arg)
        elif isinstance(arg, float):
            self._add('f', arg)
        elif isinstance(arg, (bytes, unicode)):
            self._add('s', arg)
        elif arg == None:
            self._add('N', None)
        elif arg == float('inf'):
            self._add('I', None)
        else:
            # last chance: could be a blob
            try:
                iter(arg)
            except TypeError:
                raise TypeError("unsupported message argument type")
            self._add('b', arg)


################################################################################################
#  Bundle
################################################################################################

cdef class Bundle:
    """
    Bundle([timetag, ][message, ...])

    Creates a new Bundle object. You can optionally specify a time at which the messages should be dispatched
    (as an OSC timetag float), and any number of messages to be included in the bundle.
    """
    cdef lo_bundle _bundle
    cdef list _keep_refs

    def __init__(self, *msgs):
        cdef lo_timetag tt
        tt.sec, tt.frac = 0, 0
        self._keep_refs = []

        if len(msgs) and not isinstance(msgs[0], Message):
            t = msgs[0]
            if isinstance(t, (float, int, long)):
                tt = _double_to_timetag(t)
            elif isinstance(t, tuple) and len(t) == 2:
                tt.sec, tt.frac = t
            else:
                raise TypeError("invalid timetag")
            # first argument was timetag, so continue with second
            msgs = msgs[1:]

        self._bundle = lo_bundle_new(tt)
        if len(msgs):
            self.add(*msgs)

    def __dealloc__(self):
        lo_bundle_free(self._bundle)

    def add(self, *msgs):
        """
        add(message[, ...])
        add(path[, arg, ...])

        Adds one or more messages to the bundle.
        """
        if isinstance(msgs[0], Message):
            # arguments are message objects
            for m in msgs:
                self._keep_refs.append(m)
                lo_bundle_add_message(self._bundle, (<Message>m)._path, (<Message>m)._msg)
        else:
            # arguments are one single message
            m = Message(*msgs)
            self._keep_refs.append(m)
            lo_bundle_add_message(self._bundle, (<Message>m)._path, (<Message>m)._msg)
