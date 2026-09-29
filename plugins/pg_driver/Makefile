NAME  := pg_driver

.PHONY: build-all test node-test clean

build-all:
	mkdir -p dist
	npm install --no-audit --no-fund
	npx esbuild src/index.js --bundle --platform=node --format=cjs \
		--outfile=dist/$(NAME).js --external:pg-native

test:
	node -e "const m=require('./dist/$(NAME).js');if(typeof m.Client!=='function')throw new Error('bad exports');console.log('exports ok')"

node-test: test

clean:
	rm -rf dist node_modules
