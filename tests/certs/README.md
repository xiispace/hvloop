# hvloop test certificates

Self-signed certificate + key used ONLY by the TLS test suite
(`tests/test_tls.py`). Do not use for anything real.

Why not reuse `vendor/libhv/cert/server.crt`? That certificate carries **no
subjectAltName and no CN hostname**, so Python's `ssl` hostname verification
(which requires a SAN since 3.7) can never pass against it. A committed,
long-lived self-signed pair also avoids depending on an `openssl` CLI being
present at test time on every CI platform (notably Windows).

Properties:

* CN=localhost, SAN: DNS:localhost, IP:127.0.0.1, IP:::1
* basicConstraints CA:TRUE (so the cert can act as its own trust anchor
  when loaded via `SSLContext.load_verify_locations`)
* valid 20 years from 2026-07

Regenerate with:

```sh
openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt \
  -days 7300 -nodes -subj "/C=US/O=hvloop tests/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign"
```
