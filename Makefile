.PHONY: setup check build test clean

setup:
	git submodule update --init --recursive

check: setup
	go build ./...

build: setup
	go build -o curation .

test: setup
	go test ./...

clean:
	go clean ./...
