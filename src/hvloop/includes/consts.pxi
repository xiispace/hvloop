# Constants for hvloop
cdef extern from * nogil:
    # Event flags
    int HV_READ
    int HV_WRITE
    int HV_RDWR

# Import constants from hv module
from .includes.hv cimport (
    HV_READ,
    HV_WRITE,
    HV_RDWR,
    AF_INET,
    AF_INET6,
    SOCK_STREAM,
    SOCK_DGRAM,
    SOL_SOCKET,
    SO_REUSEADDR
)