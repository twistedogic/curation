.PHONY: setup build test clean

setup:
	git submodule update --init --recursive

build: setup
	go build ./...

test: setup
	go test ./...

clean:
	go clean ./...
