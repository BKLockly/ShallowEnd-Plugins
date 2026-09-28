NAME  := docker_detect
ADDON := docker.node

.PHONY: build-all test node-test clean

build-all:
	mkdir -p dist
	zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall && mv $(ADDON) dist/$(NAME)-linux-x64.node
	zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall && mv $(ADDON) dist/$(NAME)-linux-arm64.node

test:
	zig build test

node-test:
	node test.js

clean:
	rm -rf dist .zig-cache $(ADDON)
