NAME  := sqlite_driver

.PHONY: build-all test node-test clean

build-all:
	mkdir -p dist
	npm install --no-audit --no-fund
	npx esbuild src/index.js --bundle --minify --platform=node --format=cjs \
		--outfile=dist/$(NAME).js \
		--banner:js="const __dirname='/';const __filename='/index.js';"

# bundle 带 const __dirname banner（Emscripten 修复），Node require 包装器自带
# __dirname 参数会撞声明——不能直接 require 验证；test.js 走 payload 同款
# new Function 加载（真实消费路径），同时覆盖建表/写回/Buffer 直开全链路
test:
	node test.js

node-test:
	node test.js

clean:
	rm -rf dist node_modules
