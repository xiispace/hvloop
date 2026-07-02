#ifndef HVLOOP_SHIM_H
#define HVLOOP_SHIM_H
/* hloop_t is opaque in the public hloop.h; the struct definition lives in
 * libhv's internal header event/hevent.h, which is already on our include
 * path. Including the real header keeps field offsets correct for the
 * vendored libhv version. */
#include "hevent.h"

static inline void hvloop_set_status_running(hloop_t* loop) {
    loop->status = HLOOP_STATUS_RUNNING;
}
static inline void hvloop_set_status_stop(hloop_t* loop) {
    loop->status = HLOOP_STATUS_STOP;
}

/* ---------------------------------------------------------------------------
 * TCP (M2a) helpers.
 * ------------------------------------------------------------------------- */

/* hio_close() defers the actual close while the write queue is non-empty and
 * io->error == 0 (graceful flush, nio.c). Setting an error first forces the
 * immediate-close path; transport.abort() uses this to discard the buffer. */
static inline void hvloop_hio_set_error(hio_t* io, int err) {
    io->error = err;
}

/* shutdown(SHUT_WR) for transport.write_eof(); libhv has no half-close API
 * (tech design section 6). SD_SEND == SHUT_WR == 1, but spell both out. */
static inline int hvloop_shutdown_wr(int fd) {
#ifdef OS_WIN
    return shutdown(fd, SD_SEND);
#else
    return shutdown(fd, SHUT_WR);
#endif
}

/* Release an hio that wraps a *caller-owned* fd (create_server(sock=...))
 * WITHOUT closing the fd (tech design section 7: the fd stays owned by the
 * Python socket object).
 *   - all callbacks/context are cleared so nothing re-enters Python;
 *   - io_type is reset to HIO_TYPE_UNKNOWN so hio_close() skips
 *     closesocket(io->fd) (nio.c only closes HIO_TYPE_SOCKET/PIPE fds);
 *   - hio_close() then unregisters the fd from the io watcher (hio_done ->
 *     hio_del) and clears any pending-event flags.
 * The hio_t struct itself intentionally stays in loop->ios: freeing it here
 * (hio_detach + hio_free) could leave a dangling pointer in the loop's
 * pending-event queue if this runs from inside an io callback of the same
 * poll iteration. libhv reuses the slot on the next hio_get(fd) and frees it
 * in hloop_free. */
static inline void hvloop_hio_release_external(hio_t* io) {
    hio_setcb_accept(io, NULL);
    hio_setcb_connect(io, NULL);
    hio_setcb_read(io, NULL);
    hio_setcb_write(io, NULL);
    hio_setcb_close(io, NULL);
    hio_set_context(io, NULL);
    hevent_set_userdata(io, NULL);
    hio_set_type(io, HIO_TYPE_UNKNOWN);
    hio_close(io);
}

/* ---------------------------------------------------------------------------
 * fd watching (M2b) helpers.
 * ------------------------------------------------------------------------- */

/* Clear io->revents after the raw fd-watcher callback dispatched the
 * reader/writer handles. hio_add(io, cb, events) REPLACES the io's
 * event-dispatch callback (hloop.c: io->cb = cb), so nio.c's
 * hio_handle_events never runs for watched fds and its end-of-dispatch
 * ``io->revents = 0`` must be mirrored here: the iowatcher backends
 * accumulate readiness with |= (e.g. kqueue.c: io->revents |= HV_READ), so a
 * stale bit would mis-dispatch the wrong direction on the io's next wakeup. */
static inline void hvloop_io_clear_revents(hio_t* io) {
    io->revents = 0;
}

/* Pending socket error (SO_ERROR). libhv's nio_connect reports a failed
 * connect via getpeername()'s errno (EINVAL on macOS, ENOTCONN on Linux)
 * instead of the real connect error; the close dispatch for a connecting
 * transport queries SO_ERROR to recover e.g. ECONNREFUSED. Returns the
 * pending error, 0 if none, -1 if getsockopt itself failed. */
static inline int hvloop_sock_error(int fd) {
    int err = 0;
    socklen_t len = (socklen_t)sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&err, &len) != 0) {
        return -1;
    }
    return err;
}

/* Decode a sockaddr into (family, ip, port, flowinfo, scope_id) for
 * transport.get_extra_info('sockname'/'peername'). Returns the address
 * family, or -1 if sa is NULL / undecodable. */
static inline int hvloop_sockaddr_info(struct sockaddr* sa,
                                       char* ip, int iplen, int* port,
                                       uint32_t* flowinfo, uint32_t* scope_id) {
    *port = 0;
    *flowinfo = 0;
    *scope_id = 0;
    if (sa == NULL) return -1;
    if (sa->sa_family == AF_INET) {
        struct sockaddr_in* sin = (struct sockaddr_in*)sa;
        if (inet_ntop(AF_INET, &sin->sin_addr, ip, iplen) == NULL) return -1;
        *port = (int)ntohs(sin->sin_port);
        return AF_INET;
    }
    if (sa->sa_family == AF_INET6) {
        struct sockaddr_in6* sin6 = (struct sockaddr_in6*)sa;
        if (inet_ntop(AF_INET6, &sin6->sin6_addr, ip, iplen) == NULL) return -1;
        *port = (int)ntohs(sin6->sin6_port);
        *flowinfo = ntohl(sin6->sin6_flowinfo);
        *scope_id = (uint32_t)sin6->sin6_scope_id;
        return AF_INET6;
    }
    return (int)sa->sa_family;
}

#endif
