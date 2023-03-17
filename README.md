# zig-hcs-client

A simple REPL for controlling Zig's incremental and hot-code swapping modes. The usage looks something like this:

On the Zig source side, build the binary in server mode

```
$ zig build-exe hello.zig -fno-LLVM --listen 127.0.0.1:12345
```

Next, in another terminal instance, run this program (address and port by default assume address `127.0.0.1` and
port `12345`)

```
$ zig build run                                             
(hcs) hot_update
> 0.11.0-dev.2150+31b759258
(hcs) hot_update
> hello
(hcs) exit
> hello
```
