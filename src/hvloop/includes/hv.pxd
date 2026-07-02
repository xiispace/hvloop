# cython: language_level=3
#
# libhv C API declarations (subset needed for the M1 loop core).
#
# Truth source: vendor/libhv/event/hloop.h
#
# NOTE on GIL discipline: every C callback typedef below is invoked by libhv
# from inside ``hloop_process_events`` while we have released the GIL. The
# Cython functions we hand to these typedefs are therefore declared
# ``noexcept nogil`` and re-acquire the GIL with ``with gil`` internally.
# Functions that may block (``hloop_process_events``) are declared ``nogil``
# so they can be called inside a ``with nogil:`` block.

from libc.stdint cimport uint32_t, uint64_t


cdef extern from "hv/hloop.h" nogil:
    # ----- opaque / event types -------------------------------------------
    ctypedef struct hloop_t
    ctypedef struct htimer_t
    ctypedef struct hidle_t
    ctypedef struct hio_t

    # Opaque view of the C ``struct sockaddr`` (full definition comes from the
    # platform headers pulled in by hloop.h -> hplatform.h).
    cdef struct sockaddr:
        pass

    ctypedef enum hevent_type_e:
        HEVENT_TYPE_NONE    = 0
        HEVENT_TYPE_IO      = 0x00000001
        HEVENT_TYPE_TIMEOUT = 0x00000010
        HEVENT_TYPE_PERIOD  = 0x00000020
        HEVENT_TYPE_TIMER   = 0x00000030
        HEVENT_TYPE_IDLE    = 0x00000100
        HEVENT_TYPE_SIGNAL  = 0x00000200
        HEVENT_TYPE_CUSTOM  = 0x00000400

    ctypedef void (*hevent_cb)  (hevent_t* ev) noexcept nogil
    ctypedef void (*htimer_cb)  (htimer_t* timer) noexcept nogil
    ctypedef void (*hidle_cb)   (hidle_t* idle) noexcept nogil

    # IO callbacks. libhv usually invokes these from hloop_process_events with
    # the GIL released, but a few fire synchronously from a Python-held-GIL
    # call (e.g. hio_write's direct-write completion, hio_close with an empty
    # write queue). ``with gil`` handles both (PyGILState_Ensure is reentrant).
    # Raw event-dispatch callback for hio_add. NOTE (M2b): hio_add REPLACES
    # the io's event-dispatch callback (hloop.c: io->cb = (hevent_cb)cb); the
    # high-level API installs nio.c's hio_handle_events there. Passing our own
    # hio_cb means libhv never reads/writes the fd itself and we get raw
    # readiness notifications (hio_revents) instead.
    ctypedef void (*hio_cb)     (hio_t* io) noexcept nogil

    ctypedef void (*haccept_cb) (hio_t* io) noexcept nogil
    ctypedef void (*hconnect_cb)(hio_t* io) noexcept nogil
    ctypedef void (*hread_cb)   (hio_t* io, void* buf, int readbytes) noexcept nogil
    ctypedef void (*hwrite_cb)  (hio_t* io, const void* buf, int writebytes) noexcept nogil
    ctypedef void (*hclose_cb)  (hio_t* io) noexcept nogil

    # The public hevent_t struct. We only touch the fields we need; libhv lays
    # the same header (HEVENT_FIELDS) at the start of htimer_t/hidle_t/hio_t,
    # so casting those to hevent_t* to reach ``loop``/``userdata`` is valid.
    ctypedef struct hevent_t:
        hloop_t*        loop
        hevent_type_e   event_type
        uint64_t        event_id
        hevent_cb       cb
        void*           userdata
        void*           privdata
        int             priority

    # ----- loop lifecycle -------------------------------------------------
    int HLOOP_FLAG_RUN_ONCE
    int HLOOP_FLAG_AUTO_FREE
    int HLOOP_FLAG_QUIT_WHEN_NO_ACTIVE_EVENTS

    hloop_t* hloop_new(int flags)
    void     hloop_free(hloop_t** pp)

    # Single iteration: poll ios (blocking up to timeout_ms, but clamped to the
    # nearest htimer), then run timers/idles/pendings. Releases nothing on its
    # own; we wrap calls in ``with nogil``.
    int hloop_process_events(hloop_t* loop, int timeout_ms) nogil

    int hloop_stop(hloop_t* loop)
    int hloop_wakeup(hloop_t* loop)

    # thread-safe; copies *ev into the loop's queue and writes the eventfd.
    void hloop_post_event(hloop_t* loop, hevent_t* ev)

    void     hloop_update_time(hloop_t* loop)
    uint64_t hloop_now_us(hloop_t* loop)

    uint32_t hloop_nios(hloop_t* loop)
    uint32_t hloop_ntimers(hloop_t* loop)

    # ----- timers ---------------------------------------------------------
    htimer_t* htimer_add(hloop_t* loop, htimer_cb cb,
                         uint32_t timeout_ms, uint32_t repeat)
    void htimer_del(htimer_t* timer)

    # ----- idle (unused in M1 but cheap to declare) -----------------------
    hidle_t* hidle_add(hloop_t* loop, hidle_cb cb, uint32_t repeat)
    void     hidle_del(hidle_t* idle)

    # ----- io (M2a: TCP transports / server) -------------------------------
    int HV_READ
    int HV_WRITE
    int HV_RDWR

    hio_t* hio_get(hloop_t* loop, int fd)
    int    hio_add(hio_t* io, hio_cb cb, int events)
    int    hio_del(hio_t* io, int events)
    void   hio_detach(hio_t* io)

    # Readiness bits (HV_READ/HV_WRITE) accumulated by the iowatcher for the
    # current dispatch; cleared via hvloop_io_clear_revents (M2b fd watching).
    int    hio_revents(hio_t* io)

    uint32_t  hio_id(hio_t* io)
    int       hio_fd(hio_t* io)
    int       hio_error(hio_t* io)
    sockaddr* hio_localaddr(hio_t* io)
    sockaddr* hio_peeraddr(hio_t* io)
    void      hio_set_context(hio_t* io, void* ctx)
    void*     hio_context(hio_t* io)
    bint      hio_is_opened(hio_t* io)
    bint      hio_is_closed(hio_t* io)

    void hio_setcb_accept (hio_t* io, haccept_cb  accept_cb)
    void hio_setcb_connect(hio_t* io, hconnect_cb connect_cb)
    void hio_setcb_read   (hio_t* io, hread_cb    read_cb)
    void hio_setcb_write  (hio_t* io, hwrite_cb   write_cb)
    void hio_setcb_close  (hio_t* io, hclose_cb   close_cb)

    void   hio_set_max_write_bufsize(hio_t* io, uint32_t size)
    size_t hio_write_bufsize(hio_t* io)
    void   hio_set_connect_timeout(hio_t* io, int timeout_ms)
    void   hio_set_peeraddr(hio_t* io, sockaddr* addr, int addrlen)

    int hio_accept (hio_t* io)
    int hio_connect(hio_t* io)
    int hio_read   (hio_t* io)
    # These two are #define'd in hloop.h (hio_read / hio_del(io, HV_READ));
    # declaring them as functions lets the C preprocessor expand them.
    int hio_read_start(hio_t* io)
    int hio_read_stop (hio_t* io)
    int hio_write  (hio_t* io, const void* buf, size_t len)
    int hio_close  (hio_t* io)


# ----- hsocket helpers (linked into hv_static from libhv/base) -------------
cdef extern from "hv/hsocket.h" nogil:
    ctypedef union sockaddr_u:
        sockaddr sa

    int sockaddr_set_ipport(sockaddr_u* addr, const char* host, int port)
    int sockaddr_len(sockaddr_u* addr)
    int tcp_nodelay(int sockfd, int on)


# Convenience setters mirroring the libhv macros (these are #defines in C, so
# we re-implement them as inline helpers here).
cdef inline void hevent_set_userdata(void* ev, void* udata) nogil:
    (<hevent_t*>ev).userdata = udata


cdef inline void* hevent_get_userdata(void* ev) nogil:
    return (<hevent_t*>ev).userdata


# ---------------------------------------------------------------------------
# Self-drive shim (src/hvloop/hvloop_shim.h).
#
# hvloop drives the loop via hloop_process_events rather than hloop_run, so the
# loop's status field stays at its initial HLOOP_STATUS_STOP. That makes
# hloop_process_events bail out right after the poll (hloop.c:170) and skip
# hloop_process_pendings, so IO callbacks (incl. the internal wakeup-fd reader)
# never run and the loop spins at 100% CPU. There is no public API to flip the
# status without entering hloop_run, so these helpers set it directly. We
# mirror hloop_run by setting RUNNING before the loop and STOP on exit.
# ---------------------------------------------------------------------------
cdef extern from "hvloop_shim.h" nogil:
    void hvloop_set_status_running(hloop_t* loop)
    void hvloop_set_status_stop(hloop_t* loop)

    # fd watching (M2b) helper; see hvloop_shim.h for rationale.
    void hvloop_io_clear_revents(hio_t* io)

    # TCP (M2a) helpers; see hvloop_shim.h for rationale.
    void hvloop_hio_set_error(hio_t* io, int err)
    int  hvloop_shutdown_wr(int fd)
    int  hvloop_sock_error(int fd)
    void hvloop_hio_release_external(hio_t* io)
    int  hvloop_sockaddr_info(sockaddr* sa, char* ip, int iplen, int* port,
                              uint32_t* flowinfo, uint32_t* scope_id)
