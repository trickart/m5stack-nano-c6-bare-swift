TOOLCHAINS := org.swift.630202603201a
TRIPLE := riscv32-none-none-eabi
ELF := .build/$(TRIPLE)/debug/Application
BIN := build/app.bin
PORT ?= /dev/cu.usbmodem*

# Add ld.lld from Swift toolchain to PATH
LLD_DIR := $(shell xcrun --toolchain $(TOOLCHAINS) -f ld.lld 2>/dev/null | xargs dirname)
export PATH := $(LLD_DIR):$(PATH)

.PHONY: build flash clean image_info

SWIFT_RUN := TOOLCHAINS=$(TOOLCHAINS) swift

build:
	@mkdir -p build
	TOOLCHAINS=$(TOOLCHAINS) swift build --triple $(TRIPLE) --toolset toolset.json
	$(SWIFT_RUN) Tools/elf2image.swift \
		--flash_mode dio --flash_freq 80m --flash_size 2MB \
		-o $(BIN) $(ELF)

flash: build
	$(SWIFT_RUN) Tools/write-flash.swift \
		-b 460800 \
		0x0     bootloader/bootloader.bin \
		0x8000  bootloader/partition-table.bin \
		0x10000 $(BIN)

image_info: build
	$(SWIFT_RUN) Tools/image-info.swift $(BIN)

clean:
	rm -rf .build build
