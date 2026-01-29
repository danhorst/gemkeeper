.PHONY: all build test fmt clean

# Find all tool directories under cmd/
TOOLS := $(wildcard cmd/*)
BINARIES := $(notdir $(TOOLS))

all: build

build:
	@for tool in $(BINARIES); do \
		if [ -d "cmd/$$tool" ] && [ -f "cmd/$$tool/main.go" ]; then \
			echo "Building $$tool..."; \
			go build -o bin/$$tool ./cmd/$$tool; \
		fi \
	done

test:
	go test .

fmt:
	gofmt -w .

clean:
	rm -f bin/*
	@# Preserve agent-setup script
	@git checkout bin/agent-setup 2>/dev/null || true
