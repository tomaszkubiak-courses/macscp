import asyncio
import ipaddress
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


async def socks5(reader, writer):
    count = (await reader.readexactly(2))[1]
    await reader.readexactly(count)
    writer.write(b"\x05\x00")
    _, _, _, atyp = await reader.readexactly(4)
    if atyp == 3:
        host = (await reader.readexactly((await reader.readexactly(1))[0])).decode()
    else:
        host = str(ipaddress.ip_address(await reader.readexactly(4 if atyp == 1 else 16)))
    port = int.from_bytes(await reader.readexactly(2), "big")
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection(host, port)
    except OSError:
        writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
        writer.close()
        return
    writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    await writer.drain()
    await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))


async def handle(reader, writer):
    first = await reader.readexactly(1)
    if first == b"\x05":
        return await socks5(reader, writer)
    request = first + await reader.readuntil(b"\r\n\r\n")
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
    servers = [await asyncio.start_server(handle, "127.0.0.1", int(port)) for port in sys.argv[1:]]
    await asyncio.gather(*(s.serve_forever() for s in servers))


asyncio.run(main())
