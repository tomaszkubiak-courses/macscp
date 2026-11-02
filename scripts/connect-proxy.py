import asyncio
import sys
import urllib.parse


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(reader, writer):
    request = await reader.readuntil(b"\r\n\r\n")
    line, rest = request.split(b"\r\n", 1)
    method, target, version = line.decode().split(" ", 2)
    if method != "CONNECT":
        url = urllib.parse.urlsplit(target)
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(url.hostname, url.port or 80)
        except OSError:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            writer.close()
            return
        path = (url.path or "/") + ("?" + url.query if url.query else "")
        headers = [h for h in rest.split(b"\r\n") if h and not h.lower().startswith((b"connection:", b"proxy-connection:"))]
        upstream_writer.write(f"{method} {path} {version}\r\n".encode() + b"\r\n".join(headers + [b"Connection: close"]) + b"\r\n\r\n")
        await upstream_writer.drain()
        await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))
        return
    host, port = target.rsplit(":", 1)
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(host.strip("[]"), int(port))
    except OSError:
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        writer.close()
        return
    writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
    await writer.drain()
    await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", int(sys.argv[1]))
    async with server:
        await server.serve_forever()


asyncio.run(main())
