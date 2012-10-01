#------------------------------------------------------------------------------

# Python 3 buffer interface (PEP 3118)
cdef extern from "Python.h":
    ctypedef struct Py_buffer:
        void *obj
        void *buf
        Py_ssize_t len
        Py_ssize_t itemsize
        bint readonly
        char *format
        #int ndim
        #Py_ssize_t *shape
        #Py_ssize_t *strides
        #Py_ssize_t *suboffsets
    cdef enum:
        PyBUF_SIMPLE
        PyBUF_WRITABLE
        PyBUF_FORMAT
        PyBUF_ANY_CONTIGUOUS
        PyBUF_ND
        PyBUF_STRIDES
    int  PyObject_CheckBuffer(object)
    int  PyObject_GetBuffer(object, Py_buffer *, int) except -1
    void PyBuffer_Release(Py_buffer *)
    int  PyBuffer_FillInfo(Py_buffer *, object,
                           void *, Py_ssize_t,
                           bint, int) except -1

# Python 2 buffer interface (legacy)
cdef extern from "Python.h":
    ctypedef void const_void "const void"
    int PyObject_CheckReadBuffer(object)
    int PyObject_AsReadBuffer (object, const_void **, Py_ssize_t *) except -1
    int PyObject_AsWriteBuffer(object, void **, Py_ssize_t *) except -1
    object PyBuffer_FromObject(object, Py_ssize_t, Py_ssize_t)
    object PyBuffer_FromReadWriteObject(object, Py_ssize_t, Py_ssize_t)

#------------------------------------------------------------------------------

cdef extern from *:
    enum: PYPY "PyMPI_RUNTIME_PYPY"

cdef type array_array
cdef type numpy_array
if PYPY: from array   import array   as array_array
if PYPY: from numpypy import ndarray as numpy_array

cdef int \
PyPy_GetBuffer(object obj, Py_buffer *view, int flags) \
except -1:
    cdef Py_ssize_t addr = 0
    cdef Py_ssize_t size = 0
    cdef bint readonly = 0
    if isinstance(obj, bytes):
        addr = <Py_ssize_t> PyBytes_AsString(obj)
        size = PyBytes_Size(obj)
        readonly = 1
    #elif isinstance(obj, bytearray):
    #    addr = <Py_ssize_t> PyByteArray_AsString(obj)
    #    size = PyByteArray_Size(obj)
    #    readonly = 0
    elif isinstance(obj, array_array):
        addr, size = obj.buffer_info()
        size *= obj.itemsize
        readonly = 0
    elif isinstance(obj, numpy_array):
        addr, readonly = obj.__array_interface__['data']
        size =  obj.size
        size *= obj.itemsize
    else:
        if (flags & PyBUF_WRITABLE) == PyBUF_WRITABLE:
            readonly = 0
            PyObject_AsWriteBuffer(obj, <void**>&addr, &size)
        else:
            readonly = 1
            PyObject_AsReadBuffer(obj, <const_void**>&addr, &size)
    PyBuffer_FillInfo(view, obj, <void*>addr, size, readonly, flags)
    if (flags & PyBUF_FORMAT) == PyBUF_FORMAT: view.format = b"B"
    return 0

#---------------------------------------------------------------------

cdef int \
PyObject_GetBufferEx(object obj, Py_buffer *view, int flags) \
except -1:
    if view == NULL: return 0
    if PYPY: # special-case PyPy runtime
        return PyPy_GetBuffer(obj, view, flags)
    # Python 3 buffer interface (PEP 3118)
    if PyObject_CheckBuffer(obj):
        return PyObject_GetBuffer(obj, view, flags)
    # Python 2 buffer interface (legacy)
    if (flags & PyBUF_WRITABLE) == PyBUF_WRITABLE:
        view.readonly = 0
        PyObject_AsWriteBuffer(obj, &view.buf, &view.len)
    else:
        view.readonly = 1
        PyObject_AsReadBuffer(obj, <const_void**>&view.buf, &view.len)
    PyBuffer_FillInfo(view, obj, view.buf, view.len, view.readonly, flags)
    if (flags & PyBUF_FORMAT) == PyBUF_FORMAT: view.format = b"B"
    return 0

#---------------------------------------------------------------------

cdef class _p_buffer:
    cdef Py_buffer view

    def __dealloc__(self):
        PyBuffer_Release(&self.view)

    # buffer interface (PEP 3118)
    def __getbuffer__(self, Py_buffer *view, int flags):
        if view == NULL: return
        if view.obj == <void*>None: Py_CLEAR(view.obj)
        if self.view.obj != NULL:
            PyObject_GetBufferEx(<object>self.view.obj, view, flags)
        else:
            PyBuffer_FillInfo(view, <object>NULL,
                              self.view.buf, self.view.len,
                              self.view.readonly, flags)

    def __releasebuffer__(self, Py_buffer *view):
        if view == NULL: return
        PyBuffer_Release(view)

    # buffer interface (legacy)
    def __getsegcount__(self, Py_ssize_t *lenp):
        if lenp != NULL:
            lenp[0] = self.view.len
        return 1
    def __getreadbuffer__(self, Py_ssize_t idx, void **p):
        if idx != 0: raise SystemError(
            "accessing non-existent buffer segment")
        p[0] = self.view.buf
        return self.view.len
    def __getwritebuffer__(self, Py_ssize_t idx, void **p):
        if idx != 0: raise SystemError(
            "accessing non-existent buffer segment")
        if self.view.readonly:
            raise TypeError("object is not writeable")
        p[0] = self.view.buf
        return self.view.len


cdef inline _p_buffer newbuffer():
    return <_p_buffer>_p_buffer.__new__(_p_buffer)

cdef inline _p_buffer getbuffer(object ob, bint readonly, bint format):
    cdef _p_buffer buf = newbuffer()
    cdef int flags = PyBUF_ANY_CONTIGUOUS
    if not readonly:
        flags |= PyBUF_WRITABLE
    if format:
        flags |= PyBUF_FORMAT
    PyObject_GetBufferEx(ob, &buf.view, flags)
    return buf

cdef inline object getformat(_p_buffer buf):
    cdef Py_buffer *view = &buf.view
    #
    if buf.view.obj == NULL:
        if view.format != NULL:
            return mpistr(view.format)
        else:
            return "B"
    elif view.format != NULL:
        # XXX this is a hack
        if view.format != <char*>b"B":
            return mpistr(view.format)
    #
    cdef object ob = <object>buf.view.obj
    cdef str format = None
    try: # numpy.ndarray
        format = ob.dtype.char
    except (AttributeError, TypeError):
        try: # array.array
            format =  ob.typecode
        except (AttributeError, TypeError):
            if view.format != NULL:
                format = mpistr(view.format)
    return format

cdef inline _p_buffer tobuffer(void *p, Py_ssize_t n, bint ro):
    cdef _p_buffer buf = newbuffer()
    cdef Py_buffer *view = &buf.view
    PyBuffer_FillInfo(view, <object>NULL, p, n, ro,
                      PyBUF_FORMAT|PyBUF_STRIDES)
    return buf

#------------------------------------------------------------------------------

cdef inline _p_buffer getbuffer_r(object ob, void **base, MPI_Aint *size):
    cdef _p_buffer buf = getbuffer(ob, 1, 0)
    if base != NULL: base[0] = <void*>    buf.view.buf
    if size != NULL: size[0] = <MPI_Aint> buf.view.len
    return buf

cdef inline _p_buffer getbuffer_w(object ob, void **base, MPI_Aint *size):
    cdef _p_buffer buf = getbuffer(ob, 0, 0)
    if base != NULL: base[0] = <void*>    buf.view.buf
    if size != NULL: size[0] = <MPI_Aint> buf.view.len
    return buf

#------------------------------------------------------------------------------
