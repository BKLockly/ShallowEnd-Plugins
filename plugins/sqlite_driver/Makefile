NAME  := sqlite_driver

.PHONY: build-all test node-test clean

build-all:
	mkdir -p dist
	npm install --no-audit --no-fund
	npx esbuild src/index.js --bundle --minify --platform=node --format=cjs \
		--outfile=dist/$(NAME).js \
		--banner:js="const __dirname='/';const __filename='/index.js';"

test:
	node -e "const m=require('./dist/$(NAME).js');if(typeof m.Database!=='function')throw new Error('bad exports');console.log('exports ok')"

node-test:
	node test.js

clean:
	rm -rf dist node_modules
