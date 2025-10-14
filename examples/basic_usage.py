"""
Basic usage example for hvloop
"""
import asyncio
import hvloop


def main():
    # Install hvloop event loop policy
    hvloop.install()

    async def handle_client(reader, writer):
        """Handle client connection"""
        addr = writer.get_extra_info('peername')
        print(f"Connected from {addr}")

        try:
            while True:
                data = await reader.read(1024)
                if not data:
                    break

                print(f"Received: {data.decode()}")
                writer.write(data)
                await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()
            print(f"Disconnected from {addr}")

    async def echo_server():
        """Echo server implementation"""
        server = await asyncio.start_server(
            handle_client,
            '127.0.0.1',
            8888
        )

        addr = server.sockets[0].getsockname()
        print(f'Serving on {addr}')

        async with server:
            await server.serve_forever()

    # Run the server
    asyncio.run(echo_server())


if __name__ == "__main__":
    main()