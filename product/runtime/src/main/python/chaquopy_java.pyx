from __future__ import absolute_import, division, print_function

from importlib import import_module
import sys

from cpython.module cimport PyImport_ImportModule
from cpython.object cimport PyObject
from cpython.ref cimport Py_INCREF, Py_DECREF
cdef extern from "Python.h":
    void Py_Initialize()
    void PyEval_SaveThread()

from libc.errno cimport errno
from libc.stdio cimport printf, snprintf
from libc.stdint cimport uintptr_t
from libc.stdlib cimport malloc
from libc.string cimport strerror, strlen
from posix.stdlib cimport putenv

from chaquopy.reflect import *
from chaquopy.signatures import jni_sig
from chaquopy.jni cimport *
from chaquopy.chaquopy cimport *
cdef extern from "chaquopy_java_extra.h":
    void PyInit_chaquopy_java() except *                 # These may be preprocessor macros.
    bint set_path(JNIEnv *env, const char *python_path)  #

cdef public jint JNI_OnLoad(JavaVM *jvm, void *reserved):
    return JNI_VERSION_1_6


# === com.chaquo.python.Python ================================================

# WARNING: This function (specifically the module initialization function) will crash if called
# more than once.
cdef public void Java_com_chaquo_python_Python_startNative \
    (JNIEnv *env, jclass klass, jobject j_python_path):
    # All code run before Py_Initialize must compile to pure C.
    cdef const char *python_path
    if j_python_path != NULL:
        python_path = env[0].GetStringUTFChars(env, j_python_path, NULL)
        if python_path == NULL:
            pyexception(env, "GetStringUTFChars failed")
            return
        try:
            if not set_path(env, python_path):
                return
        finally:  # Yes, this does compile to pure C, with the help of "goto".
            env[0].ReleaseStringUTFChars(env, j_python_path, python_path)

    Py_Initialize()  # Calls abort() on failure

    # We can now start using some Python constructs, but many things will still cause a native
    # crash until our module initialization function completes. In particular, global and
    # built-in names won't be bound.
    cdef JavaVM *jvm = NULL
    try:
        PyInit_chaquopy_java()

        # Normal Cython functionality is now available.
        ret = env[0].GetJavaVM(env, &jvm)
        if ret != 0:
             raise Exception(f"GetJavaVM failed: {ret}")
        set_jvm(jvm)

    except Exception as e:
        wrap_exception(env, e)
        return

    # We imported chaquopy.chaquopy above, which has called PyEval_InitThreads during its own
    # module intialization, so the GIL now exists and we have it. We must release the GIL
    # before we return to Java so that the methods below can be called from any thread.
    # (http://bugs.python.org/issue1720250)
    PyEval_SaveThread();


# This runs before Py_Initialize, so it must compile to pure C.
# "public" because its name is referenced from a preprocessor macro in chaquopy_java_extra.h.
cdef public bint set_path_env(JNIEnv *env, const char *python_path):
    # setenv is easier to use, but is not available on MSYS2.
    cdef const char *putenvPrefix = "PYTHONPATH="
    cdef int putenvArgLen = strlen(putenvPrefix) + strlen(python_path) + 1
    cdef char *putenvArg = <char*>malloc(putenvArgLen)
    if snprintf(putenvArg, putenvArgLen, "%s%s", putenvPrefix, python_path) != (putenvArgLen - 1):
        pyexception(env, "snprintf failed")
        return False

    # putenv takes ownership of the string passed to it.
    if putenv(putenvArg) != 0:
        pyexception(env, "putenv failed")
        return False

    return True


cdef public jobject Java_com_chaquo_python_Python_getModule \
    (JNIEnv *env, jobject this, jobject j_name) with gil:
    try:
        return p2j_pyobject(env, import_module(j2p_string(env, j_name)))
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_Python_getBuiltins \
    (JNIEnv *env, jobject this) with gil:
    try:
        return p2j_pyobject(env, import_module("six.moves.builtins"))
    except Exception as e:
        wrap_exception(env, e)
        return NULL

# === com.chaquo.python.PyObject ==============================================

cdef public void Java_com_chaquo_python_PyObject_openNative \
    (JNIEnv *env, jobject this) with gil:
    try:
        Py_INCREF(j2p_pyobject(env, this))
    except Exception as e:
        wrap_exception(env, e)


cdef public void Java_com_chaquo_python_PyObject_closeNative \
    (JNIEnv *env, jobject this) with gil:
    try:
        Py_DECREF(j2p_pyobject(env, this))
    except Exception as e:
        wrap_exception(env, e)


cdef public jobject Java_com_chaquo_python_PyObject_fromJava \
    (JNIEnv *env, jobject klass, jobject o) with gil:
    try:
        return p2j_pyobject(env, j2p(env, None, o))
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_PyObject_toJava \
    (JNIEnv *env, jobject this, jobject to_klass) with gil:
    try:
        self = j2p_pyobject(env, this)
        Class = autoclass("java.lang.Class")
        to_sig = jni_sig(Class(instance=GlobalRef.create(env, to_klass)))
        try:
            result = p2j(env, to_sig, self)
        except TypeError as e:
            wrap_exception(env, e, "java.lang.ClassCastException")
            return NULL
        return result.return_ref(env)
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jlong Java_com_chaquo_python_PyObject_id \
    (JNIEnv *env, jobject this) with gil:
    try:
        return id(j2p_pyobject(env, this))
    except Exception as e:
        wrap_exception(env, e)
        return 0


cdef public jobject Java_com_chaquo_python_PyObject_type \
    (JNIEnv *env, jobject this) with gil:
    try:
        return p2j_pyobject(env, type(j2p_pyobject(env, this)))
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_PyObject_call \
    (JNIEnv *env, jobject this, jarray jargs) with gil:
    try:
        if jargs == NULL:
            # User typed ".call(null)", which Java interprets as a null array, rather than the
            # array of one null which they intended.
            all_args = [None]
        else:
            all_args = j2p_array(env, "Ljava/lang/Object;", jargs)

        Kwarg = autoclass("com.chaquo.python.Kwarg")
        args = []
        kwargs = {}
        for a in all_args:
            if isinstance(a, Kwarg):
                if a.key in kwargs:
                    raise SyntaxError(f"keyword argument repeated: '{a.key}'")
                kwargs[a.key] = a.value
            else:
                if kwargs:
                    raise SyntaxError("positional argument follows keyword argument")
                args.append(a)

        result = j2p_pyobject(env, this)(*args, **kwargs)
        return p2j_pyobject(env, result)

    except Exception as e:
        wrap_exception(env, e)
        return NULL


# === com.chaquo.python.PyObject (Map) ========================================

cdef public jboolean Java_com_chaquo_python_PyObject_containsKey \
    (JNIEnv *env, jobject this, jobject j_key) with gil:
    try:
        self = j2p_pyobject(env, this)
        key = j2p(env, None, j_key)
        # https://github.com/cython/cython/issues/1702
        return __builtins__.hasattr(self, key)
    except Exception as e:
        wrap_exception(env, e)
        return False


cdef public jobject Java_com_chaquo_python_PyObject_get \
    (JNIEnv *env, jobject this, jobject j_key) with gil:
    try:
        self = j2p_pyobject(env, this)
        key = j2p(env, None, j_key)
        try:
            value = getattr(self, key)
        except AttributeError:
            return NULL
        return p2j_pyobject(env, value)
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_PyObject_put \
    (JNIEnv *env, jobject this, jobject j_key, jobject j_value) with gil:
    try:
        self = j2p_pyobject(env, this)
        key = j2p(env, None, j_key)
        try:
            old_value = getattr(self, key)
        except AttributeError:
            old_value = None
        setattr(self, key, j2p(env, None, j_value))
        return p2j_pyobject(env, old_value)
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_PyObject_remove \
    (JNIEnv *env, jobject this, jobject j_key) with gil:
    try:
        self = j2p_pyobject(env, this)
        key = j2p(env, None, j_key)
        try:
            old_value = getattr(self, key)
        except AttributeError:
            return NULL
        delattr(self, key)
        return p2j_pyobject(env, old_value)
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jobject Java_com_chaquo_python_PyObject_dir \
    (JNIEnv *env, jobject this) with gil:
    cdef JavaObject keys
    try:
        keys = autoclass("java.util.ArrayList")()
        for key in dir(j2p_pyobject(env, this)):
            keys.add(key)
        return keys.j_self.return_ref(env)
    except Exception as e:
        wrap_exception(env, e)
        return NULL

# === com.chaquo.python.PyObject (Object) =====================================

cdef public jboolean Java_com_chaquo_python_PyObject_equals \
    (JNIEnv *env, jobject this, jobject that) with gil:
    try:
        return j2p_pyobject(env, this) == j2p(env, None, that)
    except Exception as e:
        wrap_exception(env, e)
        return False


cdef public jobject Java_com_chaquo_python_PyObject_toString \
    (JNIEnv *env, jobject this) with gil:
    return to_string(env, this, str)

cdef public jobject Java_com_chaquo_python_PyObject_repr \
    (JNIEnv *env, jobject this) with gil:
    return to_string(env, this, repr)

cdef jobject to_string(JNIEnv *env, jobject this, func):
    try:
        self = j2p_pyobject(env, this)
        return p2j_string(env, func(self)).return_ref(env)
    except Exception as e:
        wrap_exception(env, e)
        return NULL


cdef public jint Java_com_chaquo_python_PyObject_hashCode \
    (JNIEnv *env, jobject this) with gil:
    try:
        return hash(j2p_pyobject(env, this)) & 0x7FFFFFFF
    except Exception as e:
        wrap_exception(env, e)
        return 0

# =============================================================================

# TODO if this is a Java exception, use the original exception object.
# TODO Integrate Python traceback into Java traceback if possible
#
# To do either of these things, create a new function called wrap_exception, rename this
# original function, and only call it directly from Python_start() when module initialization
# failed, in which case neither of these things will be possible.
cdef wrap_exception(JNIEnv *env, Exception e, clsname="com.chaquo.python.PyException"):
    # Cython translates "import" into code which references the chaquopy_java module object,
    # which doesn't exist if the module initialization function failed with an exception. So
    # we'll have to do it manually.
    try:
        traceback = PyImport_ImportModule("traceback")
        result = traceback.format_exc()
    except Exception as e2:
        result = (f"{type(e).__name__}: {e} "
                  f"[Failed to get traceback: {type(e2).__name__}: {e2}]")
    java_exception(env, result.encode("UTF-8"), clsname.replace(".", "/"))


# This may run before Py_Initialize, so it must compile to pure C.
cdef void pyexception(JNIEnv *env, char *message):
    java_exception(env, message, "com/chaquo/python/PyException")

# This may run before Py_Initialize, so it must compile to pure C.
cdef void java_exception(JNIEnv *env, char *message, char *clsname):
    cdef jclass re = env[0].FindClass(env, clsname)
    if re != NULL:
        if env[0].ThrowNew(env, re, message) == 0:
            return
    printf("Failed to throw Java exception: %s", message)