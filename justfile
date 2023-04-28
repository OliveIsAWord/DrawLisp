run:
    zig build run
    
rf:
    zig build run -freference-trace
    
build:
    zig build

test:
    zig build test

fmt:
    zig fmt .
    
rfast: 
    zig build run -Drelease-fast=true
    
rsafe:
    zig build run -Drelease-safe=true
    
rsmall:
    zig build run -Drelease-small=true

r: run
b: build
t: test
f: fmt
