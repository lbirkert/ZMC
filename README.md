```
 $$$$$$$$\ $$\      $$\  $$$$$$\
 \____$$ | $$$\    $$$ |$$  __$$\
     $$  / $$$$\  $$$$ |$$ /  \__|
    $$  /  $$\$$\$$ $$ |$$ |
   $$  /   $$ \$$$  $$ |$$ |
  $$  /    $$ |\$  /$$ |$$ |  $$\
 $$$$$$$$\ $$ | \_/ $$ |\$$$$$$  |
 \________|\__|     \__| \______/
```

`ZMC` is an asynchronous reverse proxy for [Minecraft](https://minecraft.net) written in [ZIG](https://ziglang.org).

It allows you to host multiple Minecraft servers reachable over different domains via a single IP address.

**NOTE** `ZMC` requires the latest ZIG version from the `master` branch.

<hr>

## Cloning

`git clone --recursive https://github.com/KekOnTheWorld/ZMC`

<hr>

## Configuration

The file path can be passed as a commandline argument to `ZMC`: `zig build run -- yourconfig.zon`

The configuration itself is in the `ZON` (**Z**ig **O**bject **N**otation) file format.

An example configuration can be found at `config.zon`.

#### address

The address the server will listen on. Recommended is `0.0.0.0` for IPv4 and `::1` for IPv6.

#### port

The port the server will listen on. Minecraft uses `25565` as its default port.

#### gateways

An array of gateways. A gateway contains a hostname (the domain this gateway will be accessible from, which
should have an A/AAAA record pointing to the server `ZMC` is running on), an address (the address to your
local Minecraft server; probably `localhost`/`127.0.0.1`/`::1`), and a port (the port of your local
Minecraft server).

<hr>

## Building

`zig build -Doptimize=ReleaseSafe`

`zig build -Doptimize=ReleaseSmall`

`zig build -Doptimize=ReleaseFast`

The executable will be located in the `zig-out` directory.

<hr>

## License

`ZMC` is licensed under the [MIT License](https://github.com/KekOnTheWorld/ZMC/blob/main/LICENSE).

<hr>

## Special Thanks To

- The ZIG team and foundation for making such an amazing language. [Sponsor](https://github.com/sponsors/ziglang)
- MasterQ32 for the `zig-network` library providing async I/O. [Sponsor](https://github.com/sponsors/MasterQ32)
- Everyone willing to contribute
