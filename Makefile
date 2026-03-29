TOOLCHAINS := org.swift.630202603201a
TRIPLE := riscv32-none-none-eabi
ELF := .build/$(TRIPLE)/debug/Application
BIN := build/app.bin
PORT ?= /dev/cu.usbmodem*

# Add ld.lld from Swift toolchain to PATH
LLD_DIR := $(shell xcrun --toolchain $(TOOLCHAINS) -f ld.lld 2>/dev/null | xargs dirname)
export PATH := $(LLD_DIR):$(PATH)

.PHONY: build flash clean image_info

build:
	@mkdir -p build
	TOOLCHAINS=$(TOOLCHAINS) swift build --triple $(TRIPLE) --toolset toolset.json
	. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && \
	esptool.py --chip esp32c6 elf2image \
		--flash_mode dio --flash_freq 80m --flash_size 2MB \
		-o $(BIN) $(ELF)

flash: build
	. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && \
	esptool.py --chip esp32c6 -b 460800 \
		--before default_reset --after hard_reset \
		write_flash --flash_mode dio --flash_size 2MB --flash_freq 80m \
		0x0     bootloader/bootloader.bin \
		0x8000  bootloader/partition-table.bin \
		0x10000 $(BIN)

image_info: build
	. ~/esp/esp-idf/export.sh >/dev/null 2>&1 && \
	esptool.py --chip esp32c6 image_info $(BIN)

clean:
	rm -rf .build build
