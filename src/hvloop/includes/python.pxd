# cython: language_level=3
#
# Minimal CPython API surface used by the loop core.

cdef extern from "Python.h":
    int PY_VERSION_HEX
