from libc.stdint cimport uint32_t, uint64_t
from posix.types cimport gid_t, uid_t


cdef extern from "hloop.h" nogil:
    cdef int AF_INET
    cdef int AF_INET6
    cdef int AF_UNIX
    cdef int IPPROTO_IPV6
    cdef int SOCK_STREAM
    cdef int SOCK_DGRAM
    cdef int SOL_SOCKET
    cdef int SO_REUSEADDR

    ctypedef enum hio_type_e:
        HIO_TYPE_UNKNOWN = 0
        HIO_TYPE_STDIN = 0x00000001
        HIO_TYPE_STDOUT = 0x00000002
        HIO_TYPE_STDERR = 0x00000004
        HIO_TYPE_STDIO = 0x0000000F

        HIO_TYPE_FILE = 0x00000010

        HIO_TYPE_IP = 0x00000100
        HIO_TYPE_UDP = 0x00001000
        HIO_TYPE_TCP = 0x00010000
        HIO_TYPE_SSL = 0x00020000
        HIO_TYPE_SOCKET = 0x00FFFF00


    ctypedef struct hloop_t

    ctypedef struct hevent_t:
        hloop_t*    loop
        void*   userdata
        uint64_t    event_id
        int priority

    ctypedef struct hidle_t
    ctypedef struct htimer_t
    ctypedef struct htimeout_t
    ctypedef struct hperiod_t
    ctypedef struct hio_t:
        hio_type_e io_type
        sockaddr* localaddr
        sockaddr* peeraddr

    ctypedef void (*hevent_cb)   (hevent_t* ev)
    ctypedef void (*hidle_cb)    (hidle_t* idle)
    ctypedef void (*htimer_cb)   (htimer_t* timer)
    ctypedef void (*hio_cb)      (hio_t* io)

    ctypedef void (*haccept_cb)  (hio_t* io)
    ctypedef void (*hconnect_cb) (hio_t* io)
    ctypedef void (*hread_cb)    (hio_t* io, void* buf, int readbytes)
    ctypedef void (*hwrite_cb)   (hio_t* io, const void* buf, int writebytes)
    ctypedef void (*hclose_cb)   (hio_t* io)


    hloop_t* hloop_new(int flags)

    void hloop_free(hloop_t** pp)

    int hloop_run(hloop_t* loop)
    int hloop_stop(hloop_t* loop)

    void hloop_update_time(hloop_t* loop)
    uint64_t hloop_now_us(hloop_t* loop)

    hidle_t* hidle_add(hloop_t* loop, hidle_cb cb, uint32_t repeat)
    void hidle_del(hidle_t* idle)

    htimer_t* htimer_add(hloop_t* loop, htimer_cb cb, uint32_t timeout, uint32_t repeat)
    void htimer_del(htimer_t* timer)

    void htimer_del(htimer_t* timer)
    void htimer_reset(htimer_t* timer)

    hio_t* hloop_create_tcp_client(hloop_t* loop, const char* host, int port, hconnect_cb connect_cb)
    hio_t* hloop_create_tcp_server(hloop_t* loop, const char* host, int port, haccept_cb accept_cb)

    hio_t* hloop_create_udp_server(hloop_t* loop, const char* host, int port)
    hio_t* hloop_create_udp_client(hloop_t* loop, const char* host, int port)

    # Nonblocking, poll IO events in the loop to call corresponding callback.
    int HV_READ
    int HV_WRITE
    int HV_RDWR

    void hloop_post_event(hloop_t* loop, hevent_t* ev)

    hio_t * hio_get(hloop_t* loop, int fd)
    int hio_add(hio_t* io, hio_cb cb, int events)
    int hio_del(hio_t* io, int events)

    # hio_t fields
    int hio_fd(hio_t* io)
    int hio_error(hio_t* io)
    hio_type_e hio_type(hio_t* io)
    sockaddr* hio_localaddr(hio_t* io)
    sockaddr* hio_peeraddr(hio_t* io)
    void hio_set_peeraddr(hio_t* io, sockaddr* addr, int addrlen)

    # set callbacks
    void hio_setcb_read(hio_t* io, hread_cb read_cb)
    void hio_setcb_write(hio_t* io, hwrite_cb write_cb)
    void hio_setcb_accept(hio_t* io, haccept_cb accept_cb)
    void hio_setcb_connect(hio_t* io, hconnect_cb connect_cb)
    void hio_setcb_close(hio_t* io, hclose_cb close_cb)

    # hio_add(io, HV_READ) => accept => haccept_cb
    int hio_accept (hio_t* io)
    # connect => hio_add(io, HV_WRITE) => hconnect_cb
    int hio_connect(hio_t* io)
    # hio_add(io, HV_READ) => read => hread_cb
    int hio_read   (hio_t* io)
    # hio_try_write => hio_add(io, HV_WRITE) => write => hwrite_cb
    int hio_write  (hio_t* io, const void* buf, size_t len)
    # hio_del(io, HV_RDWR) => close => hclose_cb
    int hio_close  (hio_t* io)

    int hio_read_start(hio_t* io)  # same as hio_read




    #------------------high-level apis-------------------------------------------
    # hio_get -> hio_set_readbuf -> hio_setcb_read -> hio_read
    hio_t* hread    (hloop_t* loop, int fd, void* buf, size_t len, hread_cb read_cb)
    # hio_get -> hio_setcb_write -> hio_write
    hio_t* hwrite   (hloop_t* loop, int fd, const void* buf, size_t len, hwrite_cb write_cb)
    # hio_get -> hio_close
    void   hclose   (hloop_t* loop, int fd)

    # tcp
    # hio_get -> hio_setcb_accept -> hio_accept
    hio_t* haccept  (hloop_t* loop, int listenfd, haccept_cb accept_cb)
    # hio_get -> hio_setcb_connect -> hio_connect
    hio_t* hconnect (hloop_t* loop, int connfd, hconnect_cb connect_cb)
    # hio_get -> hio_set_readbuf -> hio_setcb_read -> hio_read
    hio_t* hrecv    (hloop_t* loop, int connfd, void* buf, size_t len, hread_cb read_cb)
    # hio_get -> hio_setcb_write -> hio_write
    hio_t* hsend    (hloop_t* loop, int connfd, const void* buf, size_t len, hwrite_cb write_cb)


    #hevent.h
    # void hio_init(hio_t* io)
    # int hio_read(hio_t* io)
    # void hio_done(hio_t* io)
    # void hio_free(hio_t* io)


ctypedef enum hv_run_flag:
    HV_RUN_ONCE = 1
    HV_AUTO_FREE = 2
    HV_QUIT_WHEN_NO_ACTIVE_EVENTS = 4


cdef inline void hevent_set_userdata(hevent_t* ev, void* udata):
    (<hevent_t*>ev).userdata = udata


cdef extern from "hsocket.h" nogil:
    ctypedef int socklen_t
    struct sockaddr:
        unsigned short sa_family
        char           sa_data[14]

    struct sockaddr_in:
        unsigned short sin_family
        unsigned short sin_port
        # ...

    struct sockaddr_in6:
        unsigned short sin6_family
        unsigned short sin6_port
        unsigned long  sin6_flowinfo
        # ...
        unsigned long  sin6_scope_id

    ctypedef union sockaddr_u:
        sockaddr sa
        sockaddr_in sin
        sockaddr_in6 sin6

    int ntohs(int)
    int htonl(int)
    int ntohl(int)

    int sockaddr_set_ipport(sockaddr_u* addr, const char* host, int port)
    socklen_t sockaddr_len(sockaddr_u* addr)
    const char* sockaddr_str(sockaddr_u* addr, char* buf, int len)


