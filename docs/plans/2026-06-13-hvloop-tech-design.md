# hvloop 技术方案：基于 libhv 的 asyncio 事件循环

日期：2026-06-13
分支：`codex/refactor-native-io`
状态：待评审

## 1. 目标与范围

**目标**：用 Cython 实现一个 asyncio 兼容的事件循环扩展（定位类似 uvloop），底层复用 vendor/libhv 的跨平台事件引擎，面向 web server 场景。

**验收标准**（按优先级）：

1. uvicorn + FastAPI 能以 `--loop hvloop`（或 `hvloop.install()`）正常运行 HTTP 服务；
2. FastAPI WebSocket 端点正常工作（uvicorn 的 `websockets` / `wsproto` 实现均基于 asyncio Protocol/Transport，不需要额外协议层）；
3. Linux（epoll）、macOS（kqueue）、Windows（wepoll）三平台构建并通过 CI 测试；
4. 常见异步客户端（httpx、asyncpg、redis-py async 等基于 `create_connection` 的库）可用。

**非目标**（明确不做或降级）：

- `subprocess_exec` / `subprocess_shell`、`connect_read_pipe` / `connect_write_pipe`：抛 `NotImplementedError`（uvicorn/FastAPI 不依赖）；
- `sendfile`：回退到 asyncio 的 fallback 实现（`SendfileNotAvailableError` 路径）；
- Proactor 风格 API；
- 实现 asyncio 全部方法 —— 只做 web server 场景所需子集（见 §5）。

## 2. 现状

- 上一版实现（`loop.pyx` / `transport.pyx` / `server.pyx` / `handle.pyx`）已在 HEAD 提交中删除，CMakeLists 改为编译单一入口 `src/hvloop/_core.pyx`（待创建），即本分支是**推倒重写**。
- 构建链已就绪：scikit-build-core + cython-cmake + CMake，libhv 以静态库（`hv_static`）链入，HTTP/MQTT/evpp/OpenSSL 等模块全部关闭，只编 core event。
- 旧实现的主要教训（重写动机）：
  - 用 `hloop_run` + `hidle` 驱动：libhv 的 idle 回调**只在本轮没有 IO/定时器事件时执行**（`hloop.c:180`），且 `hloop_run` 每轮最多阻塞 `HLOOP_MAX_BLOCK_TIME = 100ms`（`hloop.c:18`）——`call_soon` 排队的回调最坏要等 100ms，繁忙时还会被 IO 事件挤占，语义与 asyncio 不符；
  - hio userdata 持有 Python 对象裸指针，没有配套的 INCREF/DECREF 纪律，存在 use-after-free 风险；
  - 多 `.pyx` 独立编译单元之间 cimport，跨模块内联与构建依赖都比较脆。

## 3. 总体架构

### 3.1 模块布局

采用 uvloop 模式：**单编译单元** `_core.pyx`，子模块通过 Cython `include` 进同一翻译单元（拿到跨"模块"内联与 cdef class 直接访问，也匹配现有 CMake 只 transpile `_core.pyx` 的设定）：

```
src/hvloop/
  __init__.py            # install() / new_event_loop() / run() / EventLoopPolicy
  includes/
    hv.pxd               # libhv C API 声明（hloop/hio/htimer/hevent）
    consts.pxi           # 常量
    python.pxd           # CPython 内部 API 声明
  _core.pyx              # 入口：include 下列文件
  loop.pyx / loop.pxd    # Loop：驱动循环、call_soon/timer/threadsafe、executor、signal
  handles.pyx            # Handle / TimerHandle
  tcp.pyx                # TCPTransport（hio 封装）+ create_connection
  server.pyx             # Server + create_server
  dns.pyx                # getaddrinfo/getnameinfo（线程池）
```

M1 阶段可以先全部写在 `_core.pyx` 一个文件里，跑通后再按上面拆 include 文件。注意：CMake 需把 include 的文件列入 `cython_transpile` 的依赖（cython-cmake 的 depfile 支持；若不生效则在 CMake 里显式 `CMAKE_CONFIGURE_DEPENDS`），否则改子文件不触发重编。

### 3.2 与 libhv 的职责划分

| 职责 | 承担方 |
|---|---|
| IO 多路复用（epoll/kqueue/wepoll）| libhv `hloop_process_events` |
| 定时器堆 | libhv `htimer`（monotonic hrtime）|
| socket 读写缓冲、写流控水位 | libhv `hio`（内部写缓冲 + `hio_write_bufsize`）|
| 跨线程唤醒 | libhv `hloop_post_event`（线程安全，内置 eventfd/socketpair）|
| ready 回调队列、asyncio 语义、Future/Task、协议/传输对象 | hvloop（Cython）|
| DNS 解析、executor | hvloop（Python 线程池，同 asyncio 做法）|

## 4. 核心设计：循环驱动模型

**不使用 `hloop_run`，由 hvloop 自驱**（uvloop 驱动 libuv 的同款思路）：

```text
run_forever():
    强制创建 wakeup eventfd（见下）
    while not _stopping:
        ntodo = len(_ready)
        逐个执行本轮快照内的 ready 回调（新入队的留到下一轮，防饿死）
        if _stopping: break
        timeout = 0 if _ready else INFINITE_OR_CAP
        with nogil:
            hloop_process_events(hvloop, timeout)   # 内部会按最近 htimer 截断阻塞时间
```

关键点：

1. **`hloop_process_events` 自带定时器截断**：阻塞时间会取 `timeout` 与最近 htimer 到期时间的最小值（`hloop.c:140-161`），所以 hvloop 不需要自己算定时器超时，只需在 ready 队列非空时传 0。
2. **wakeup fd 必须在进入循环前创建**：`hloop_process_events` 在 `nios == 0` 时直接 `hv_msleep(blocktime)`，**不可被唤醒**。而 wakeup eventfd 是 `hloop_run`/首次 `hloop_post_event` 惰性创建的。对策：`run_forever` 开头先 `hloop_post_event` 一个 no-op 事件，确保 eventfd 注册为 io（`nios >= 1`），此后循环始终阻塞在可中断的 poll 上。
3. **`call_soon`**：append 到 `_ready`（Python deque）。因为只在 loop 线程调用，无需加锁；由于 ready 非空时 poll timeout 为 0，延迟为零。
4. **`call_soon_threadsafe`**：append 到 `_ready`（CPython deque 的 append 在 GIL 下原子）+ `hloop_post_event(loop, no-op)` 打断 poll。不用 `hloop_wakeup` 之外的额外管道。
5. **`stop()`**：置 `_stopping`；跨线程时经 `call_soon_threadsafe` 路径唤醒。
6. **GIL 纪律**：poll 期间 `nogil` 释放；所有 libhv C 回调声明为 `noexcept`，体内 `with gil` 并整体 try/except，异常一律送 `call_exception_handler`，绝不穿透回 C。
7. **KeyboardInterrupt**：SIGINT 到达会 EINTR 打断 poll，回到 Python 字节码层后由解释器抛出 —— 与 asyncio 行为一致；Windows 下 uvicorn 自行用 `signal.signal` 处理，不依赖 loop。

**定时器**：`call_later`/`call_at` → `htimer_add(cb, delay_ms, repeat=1)`，`TimerHandle` 持有 `htimer_t*`；cancel → `htimer_del`。注册期间对 Handle `Py_INCREF`，触发或取消后 `DECREF`。`loop.time()` = `hloop_now_us(hvloop) / 1e6`（monotonic，与 htimer 同时间源，保证 `call_at` 语义自洽）。

## 5. asyncio API 实现清单

**必须实现（M1–M3）**：

- 生命周期：`run_forever` / `run_until_complete` / `stop` / `close` / `is_running` / `is_closed`、`shutdown_asyncgens`、`shutdown_default_executor`
- 调度：`call_soon` / `call_later` / `call_at` / `call_soon_threadsafe` / `time` / `create_future` / `create_task`、`set_task_factory` / `get_task_factory`
- 网络：`create_server`（host/port 多地址、`sock=`、backlog、reuse_address/reuse_port、start_serving，含 `Server` 对象全套：`close/wait_closed/serve_forever/sockets`）、`create_connection`（host/port、`sock=`、local_addr）
- fd 监视：`add_reader` / `remove_reader` / `add_writer` / `remove_writer`（基于 `hio_get` + `hio_add(HV_READ/HV_WRITE)`；得益于 Windows 用 wepoll 反应器后端，**三平台都可用**——这点优于 asyncio 的 ProactorEventLoop）
- DNS/executor：`getaddrinfo` / `getnameinfo`（默认线程池执行，同 asyncio）、`run_in_executor` / `set_default_executor`
- 信号：`add_signal_handler` / `remove_signal_handler`（仅 Unix；Windows 抛 `NotImplementedError`，与 asyncio Proactor 一致，uvicorn 会自动回退）
- 异常处理：`default_exception_handler` / `call_exception_handler` / `set_exception_handler`、`set_debug` / `get_debug`

**Phase 2（M4，可选）**：`create_datagram_endpoint`、`sock_recv/sock_sendall/sock_accept/sock_connect`（基于 add_reader/writer 的简单实现）、TLS（见 §8）。

**不实现**（抛 `NotImplementedError`）：subprocess 系、pipe 系、`sendfile`（走 fallback）。

## 6. TCP Transport 设计

`TCPTransport`（实现 `asyncio.Transport` 接口）封装一个 `hio_t*`：

- **读**：`hio_setcb_read` + `hio_read_start`。⚠️ libhv 的 readbuf 是 **loop 级共享缓冲**，回调返回后即被复用——回调内必须立刻 `PyBytes_FromStringAndSize` 拷贝再交给 `protocol.data_received`。`pause_reading` → `hio_read_stop`；`resume_reading` → `hio_read_start`。
- **写**：`write(data)` → `hio_write`（libhv 先尝试直写，未写完部分进内部写缓冲并自动注册 HV_WRITE）。写流控：每次 write 后查 `hio_write_bufsize`，超过 high-water → `protocol.pause_writing()`；在 `hwrite_cb` 中检查降到 low-water 以下 → `resume_writing()`。`set_write_buffer_limits` 调整水位；`get_write_buffer_size` = `hio_write_bufsize`。
- **关闭**：`close()` = 优雅关闭（停止读，待写缓冲清空后 `hio_close`，libhv 的 close 本身会 flush 残余写缓冲）；`abort()` = 直接 `hio_close`。`hclose_cb` → `protocol.connection_lost(exc)`，exc 由 `hio_error` 推断（0 → None）。
- **write_eof**：libhv 无半关闭 API，在写缓冲清空后对 fd 直接调 `shutdown(SHUT_WR)`；`can_write_eof()` 返回 True。
- **EOF 语义（已知偏差）**：libhv 收到对端 EOF 时不回调 read(0) 而是直接走 close 流程，拿不到"半关闭后继续写"的窗口。即 `protocol.eof_received()` 之后连接即关闭。对 HTTP/WebSocket（h11、httptools、websockets 均不依赖半关闭）无影响；如未来需要，可给 vendored libhv 打小 patch。
- **生命周期**：`hio_set_context(io, <void*>transport)` + 注册时 `Py_INCREF(transport)`，`hclose_cb` 末尾 `Py_DECREF`。Transport 关闭后将 `_hio` 置 NULL，所有方法判 NULL 防悬挂。
- **extra_info**：`socket`（用 `socket.socket(fileno=...)` 复制时注意所有权，提供 `dup` 视图）、`sockname` / `peername`（`hio_localaddr` / `hio_peeraddr`）。

`create_connection`：用 Python socket + `getaddrinfo` 做地址解析与多地址尝试（happy-eyeballs 不做，顺序尝试），连接用 `hio_get(fd)` + `hio_setcb_connect` + `hio_connect`（非阻塞 connect 交给 libhv），成功后构造 Transport。这样把 socket 创建/绑定细节留在 Python 侧（行为与 asyncio 一致），libhv 只管事件。

## 7. Server / create_server

- **host/port 路径**：hvloop 用 Python `socket` 自建监听 socket（getaddrinfo 多地址、`SO_REUSEADDR`/`SO_REUSEPORT`、IPv6 dualstack），`listen(backlog)` 后交给 libhv：`hio_get(loop, fd)` + `hio_setcb_accept` + `hio_accept`。
- **sock= 路径**：uvicorn 多 worker/reload 模式会传现成 socket，直接取 `fileno()` 走同样流程；Python socket 对象由 Server 持有保活（fd 所有权仍归 Python socket，关闭时先 `hio_del` 再由 socket 对象 close）。
- **accept 回调**：libhv 已完成 accept，回调里拿到新连接的 `hio_t*` → `protocol_factory()` → 构造 `TCPTransport` → `connection_made`。`Server._attach/_detach` 计数维持 `wait_closed` 语义。
- Windows 注意：Python 的 `fileno()` 返回 SOCKET 句柄（uintptr），libhv API 是 `int`——实践中句柄值在 int 范围内（libhv 全库即此假设，wepoll 同），跟随该约定，入口处加断言。

## 8. TLS 策略

- **Phase 1 不支持**：`create_server(ssl=...)` / `create_connection(ssl=...)` 抛 `NotImplementedError`。Web 部署中 TLS 终止通常在 nginx/Caddy/LB 层，不阻塞 FastAPI 验收目标。
- **Phase 2**：复用 stdlib `asyncio.sslproto.SSLProtocol`（MemoryBIO 方案，uvloop 同源做法）：hvloop 的 TCPTransport 之上套 SSLProtocol，即可直接吃 Python 的 `ssl.SSLContext`。
- **明确不用 libhv 的 OpenSSL 集成**：它与 Python `ssl.SSLContext`（证书、ALPN、SNI 配置）不互通，且会让 wheel 背上 OpenSSL 链接/分发负担。CMake 维持 `WITH_OPENSSL=OFF`。

## 9. 信号处理（Unix）

不用 libhv 的 `hsignal_add`（其实现语义与 asyncio 要求不符），照搬 CPython unix_events 方案：

- `signal.set_wakeup_fd(write_end)`，socketpair 读端注册进 hloop（`add_reader`）；
- 信号到达 → 字节写入 wakeup fd → loop 醒来 → 读出 signo → 调度已注册 handler 到 ready 队列；
- `signal.signal(sig, _noop)` 保证 C 层 handler 存在。

Windows：`add_signal_handler` 抛 `NotImplementedError`（uvicorn 检测后回退到 `signal.signal`，行为与其在 ProactorEventLoop 上一致）。

## 10. Python 包装层

```python
import hvloop

hvloop.install()                  # asyncio.set_event_loop_policy(hvloop.EventLoopPolicy())
loop = hvloop.new_event_loop()    # 直接构造 Loop
hvloop.run(main())                # 3.11+: asyncio.Runner(loop_factory=...)；3.10: 自管理等价实现
```

uvicorn 接入方式（两种都验证）：`hvloop.install()` 后 `uvicorn.run(app, loop="asyncio")`，以及为 uvicorn 注册自定义 loop setup（文档给出示例）。

## 11. 构建与发布

- 构建链不变：scikit-build-core + cython-cmake，CMake `cython_transpile(_core.pyx)` → C → 链 `hv_static`。
- libhv 选项维持现状（只编 core event）；确认 Windows 下 `WITH_WEPOLL=ON`（libhv 默认 ON，CMake 中显式 FORCE 一次防漂移）。
- Wheel 矩阵（cibuildwheel）：manylinux2014 x86_64/aarch64、musllinux、macOS x86_64 + arm64、Windows AMD64；CPython 3.10–3.13（3.14 进 CI 验证后加 classifier）。
- CI：GitHub Actions 三平台 build + pytest + FastAPI/WebSocket 集成冒烟（现有 build.yml 改造）。

## 12. 测试与验收

1. **单元**：call_soon FIFO 顺序、call_later/call_at 精度与取消、call_soon_threadsafe 跨线程唤醒延迟、stop/close 语义、异常处理器、run_until_complete 嵌套错误、shutdown_asyncgens。
2. **Transport**：echo client/server、1MB+ 大包、读暂停/恢复、写水位 pause_writing/resume_writing、对端半关/RST、abort、`sock=` 传入路径。
3. **集成（验收门槛）**：
   - uvicorn + FastAPI：JSON 端点、路径/查询参数、`def`（线程池）端点、流式响应、lifespan 启停、Ctrl-C 优雅退出；
   - FastAPI WebSocket echo + 并发广播（websockets 客户端）；
   - httpx AsyncClient 走 hvloop 的 `create_connection` 出站请求。
4. **三平台 CI** 跑 1–3；**基准**（Linux）：oha/wrk 对比 asyncio、uvloop 的 RPS/延迟，写进 README。

## 13. 里程碑

| 里程碑 | 内容 | 完成标志 |
|---|---|---|
| M1 Loop 核心 | 自驱循环、call_soon/timer/threadsafe、executor、异常处理、生命周期 | 单元测试组 1 全绿（三平台）|
| M2 TCP | TCPTransport、create_connection、create_server/Server、add_reader/writer、Unix 信号 | echo + transport 测试组 2 全绿 |
| M3 ASGI 验收 | uvicorn + FastAPI HTTP & WebSocket、文档、uvicorn 接入示例 | 集成测试组 3 三平台全绿 |
| M4 打磨 | TLS（sslproto）、UDP（可选）、sock_* 系、wheel 发布流水线、benchmark | PyPI 可装、README 含基准 |

## 14. 关键风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| libhv readbuf 为 loop 级共享缓冲 | 数据被覆盖 | read 回调内立即拷贝为 bytes（§6）|
| `nios==0` 时 `hv_msleep` 不可唤醒 | threadsafe 唤醒失效 | 启动即 post no-op 事件创建 eventfd（§4.2）|
| libhv EOF 即关闭，无半关闭窗口 | `eof_received` 语义不完整 | HTTP/WS 不受影响；记录偏差，必要时 patch vendored libhv |
| Python 对象与 hio 生命周期错配 | use-after-free / 泄漏 | 统一 INCREF-on-register / DECREF-on-close 纪律，close 后指针置 NULL |
| C 回调中 Python 异常穿透 | 进程崩溃 | 所有回调 `noexcept` + `with gil` + 全量 try/except → exception handler |
| Windows SOCKET(uintptr) vs libhv int fd | 句柄截断（理论）| 跟随 libhv 全库约定，入口断言；wepoll 同假设 |
| cython include 文件改动不触发重编 | 开发体验 | CMake 依赖声明 / depfile 验证（§3.1）|
| uvicorn 对 loop 私有行为的隐性依赖 | 集成翻车 | M3 用 uvicorn 真实跑而非模拟；遇到缺口按需补 API |
