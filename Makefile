SRC    := src/assembly_token_transfer/assembly_token_transfer.s
SO     := deploy/assembly_token_transfer.so
RUNNER := agave-ledger-tool program run
LEDGER := test-ledger
MODE   := --mode interpreter
IX_DIR := src/assembly_token_transfer

.PHONY: all build run-make run-take run-cancel run test clean

all: build run test

build: $(SO)

$(SO): $(SRC)
	@echo "==> building sBPF"
	llvm-mc -arch=bpfel -filetype=obj -o /tmp/assembly_token_transfer.o $(SRC)
	llvm-objcopy \
		--output-target=binary \
		--only-section=.text \
		/tmp/assembly_token_transfer.o \
		/tmp/assembly_token_transfer_text.bin
	llvm-objcopy \
		-I binary -O elf64-little \
		--rename-section=.data=.text \
		/tmp/assembly_token_transfer_text.bin \
		$(SO)

run-make: $(SO)
	@echo "==> run make_offer"
	$(RUNNER) $(SO) \
		--ledger $(LEDGER) \
		$(MODE) \
		--input $(IX_DIR)/instructions.json \
		--trace trace_make.txt

run-take: $(SO)
	@echo "==> run take_offer"
	$(RUNNER) $(SO) \
		--ledger $(LEDGER) \
		$(MODE) \
		--input $(IX_DIR)/instructions_take.json \
		--trace trace_take.txt

run-cancel: $(SO)
	@echo "==> run cancel_offer"
	$(RUNNER) $(SO) \
		--ledger $(LEDGER) \
		$(MODE) \
		--input $(IX_DIR)/instructions_cancel.json \
		--trace trace_cancel.txt

run: run-make run-take run-cancel

test:
	@echo "==> cargo test"
	cargo test

clean:
	rm -f /tmp/assembly_token_transfer.o \
	      /tmp/assembly_token_transfer_text.bin \
	      trace_make.txt trace_take.txt trace_cancel.txt
