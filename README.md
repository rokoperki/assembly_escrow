# assembly_token_transfer

A two-party token escrow on Solana written in raw sBPF assembly. No Rust, no Anchor, no macros — just instructions.

## The program

Two parties want to swap tokens without trusting each other or a third party. The maker deposits token A into a vault and names their price in token B. The taker pays that price and receives token A atomically. If the maker changes their mind before anyone takes the offer, they cancel and get their tokens back.

The program manages this with a PDA-owned escrow account that tracks state across calls. Three instructions drive the lifecycle.

**make_offer** — the maker deposits token A into a vault ATA and writes the terms into the escrow account: who they are, which mints are involved, how much of each, and where the vault is. The escrow state is set to Active. The instruction takes seven accounts: maker, maker_ata_a, vault_ata, escrow, mint_a, mint_b, token_program. Validation checks that the maker signed, the escrow is owned by this program, the escrow data is exactly 154 bytes, maker_ata_a belongs to the correct mint and owner, and vault_ata has the right mint. The CPI that moves tokens into the vault is authorized by the maker signing the transaction normally — no PDA involved at this stage.

**take_offer** — the taker pays the maker's asking price in token B and receives the vaulted token A. Both transfers happen in the same instruction via two consecutive CPIs to the SPL Token program. The first CPI moves token B from the taker's ATA to the maker's ATA, signed by the taker. The second moves token A from the vault to the taker's ATA, signed by the escrow PDA. Validation confirms the escrow is Active, the vault key matches what was stored in escrow at make time, the taker's token B ATA has the right mint and owner, and the maker's token B ATA matches the maker stored in escrow. The escrow state is not updated at the end — the vault is drained and the offer can no longer be taken, but the account is left as-is.

**cancel_offer** — only the original maker can cancel. The program reads the maker pubkey stored in escrow and compares it against the caller. It then issues a PDA-signed Transfer returning all vaulted tokens to the maker's ATA, and sets escrow state to Cancelled. The same signer seeds used by take_offer — `["escrow", maker_pubkey, nonce_le64, bump]` — authorize the vault withdrawal.

The escrow PDA is derived from `["escrow", maker_pubkey, nonce_le64]`. The nonce lets a maker run multiple concurrent escrows with the same pair of mints. The bump is stored in the escrow account data at offset 1 and used directly when building the signer seeds for CPIs.

## Assembly

### Input buffer layout

The Solana runtime places the input buffer at `r1` when it calls the entrypoint. The buffer begins with a `u64` account count at offset 0, then the accounts themselves packed end-to-end. Each account slot is not a fixed size — its stride depends on the account's data length:

```
stride(d) = 96 + align8(d + 10240)
```

The 96 comes from 88 bytes of fixed fields (flags, pubkey, owner, lamports, data_len, data) plus 8 bytes of `rent_epoch` appended after the data. The `10240` is `MAX_PERMITTED_DATA_INCREASE` — extra headroom the runtime reserves in case a CPI reallocs the account. `align8` rounds up to the next 8-byte boundary: `(n + 7) & ~7`.

Because stride varies per account, the program cannot index accounts with a single multiply. It walks them in a loop at the top of the entrypoint: for each account it computes the stride from the stored `data_len`, advances the pointer, and saves the account base to a stack slot before moving on. When the loop ends, `r7` is pointing at the instruction data length field (`u64`) immediately after the last account. Instruction data starts at `r7 + 8`.

The per-account fields live at these offsets from the account base:

```
+0x00  dup_info     u8   (0xFF = not a duplicate)
+0x01  is_signer    u8
+0x02  is_writable  u8
+0x03  executable   u8
+0x08  key         [u8;32]
+0x28  owner       [u8;32]
+0x48  lamports     u64
+0x50  data_len     u64
+0x58  data        [u8; data_len]
...    rent_epoch   u64  (at base + stride - 8)
```

### Register discipline

`r1`–`r5` are argument and scratch registers. Any `call` instruction — whether to an internal helper or an external syscall — clobbers them. `r6`–`r9` survive `call` instructions and are used throughout each handler to hold values that need to outlast a CPI. `r10` is the frame pointer and is fixed for the lifetime of the program; the stack grows downward from it.

The account pointers saved during the entrypoint walk are kept on the stack: acct0 at `r10-8`, acct1 at `r10-16`, acct2 at `r10-24`, and so on. After any CPI clobbers `r1`–`r5`, the handler reloads whichever account pointers it needs with `ldxdw rN, [r10 - K]` before the next use. `r7` holds the instruction data pointer through the entire dispatch; because only the entrypoint uses it before branching into a handler, and handlers do not call back through dispatch, it stays valid.

### Escrow account layout

The escrow account data is 154 bytes:

```
+0x00  state       u8   (0=Active, 1=Complete, 2=Cancelled)
+0x01  bump        u8
+0x02  nonce       u64
+0x0A  maker      [u8;32]
+0x2A  mint_a     [u8;32]
+0x4A  mint_b     [u8;32]
+0x6A  amount_a    u64
+0x72  amount_b    u64
+0x7A  vault_ata  [u8;32]
```

make_offer writes all fields after performing the Transfer CPI. cancel_offer and take_offer read bump, nonce, maker, mint_a, mint_b, amount_a, amount_b, and vault_ata from this layout to validate accounts and build signer seeds without any additional instruction data.

### CPI structs on the stack

The Solana C SDK's `sol_invoke_signed_c` function takes five arguments: a pointer to a `SolInstruction`, a pointer to an array of `SolAccountInfo`, the account count, a pointer to a `SolSignerSeeds`, and the signer count. All of these structs must exist in memory when the call happens, so the program builds them on the stack frame of the handler immediately before the `call`.

`SolAccountMeta` is 16 bytes: a pointer to the account key (8 bytes), `is_writable` (1 byte), `is_signer` (1 byte), and 6 bytes of padding. `SolInstruction` is 40 bytes: program id pointer, accounts array pointer, accounts array length, data pointer, data length — all 8 bytes each. `SolAccountInfo` is 56 bytes: key pointer, lamports pointer, data length, data pointer, owner pointer, rent_epoch value, is_signer, is_writable, executable — the last three packed in 8 bytes. `SolSignerSeed` is 16 bytes: seed bytes pointer and seed length. `SolSignerSeeds` is 16 bytes: seeds array pointer and seed count.

Each struct field is written with explicit `stxdw` and `stxb` instructions. Pointer fields point into the input buffer — for example, the key pointer in a `SolAccountMeta` points at `acct.key = acct_base + 0x08`. The key never needs to be copied; the pointer into the runtime-provided buffer is sufficient.

`rent_epoch` is a special case. It does not sit at a fixed offset from the account base — it sits at the end of each account slot, which means its offset is `stride - 8`. The program exploits the layout: after the account walk, each account's `rent_epoch` is at `next_account_base - 8`. `fill_acct_info` therefore takes a `next_acct_ptr` argument alongside the account pointer and reads `[next_acct_ptr - 8]` to get `rent_epoch`. The last account in a handler passes its own `ix_data_len_ptr` as `next_acct_ptr` since that immediately follows in the buffer.

### Helpers

Four helper functions reduce repetition. `cmp32` takes two pointers and returns 0 if the 32 bytes they point to are equal, 1 otherwise — it reads four 8-byte words and short-circuits on the first mismatch. `copy32` copies 32 bytes from source to destination in four 8-byte stores.

`fill_meta` writes one `SolAccountMeta` struct. It takes the destination pointer in `r1`, an account base pointer in `r2`, `is_writable` in `r3`, and `is_signer` in `r4`. It adds `ACCT_KEY` to `r2` in place and stores the resulting pointer, then stores the two flag bytes.

`fill_acct_info` writes one `SolAccountInfo` struct. It takes the destination in `r1`, the account pointer in `r2`, the next-account pointer in `r3` (for `rent_epoch`), `is_signer` in `r4`, and `is_writable` in `r5`. It uses `r0` as scratch throughout — not `r6`–`r9` — so that callees do not have to save and restore caller-saved registers. Each pointer field is computed as `r2 + field_offset`, stored with `stxdw`.

Because `call` gives helpers their own stack frame, all destination addresses are passed explicitly as pointers in the argument registers. A helper cannot write to a caller's stack slot via a hardcoded `r10-N` offset because its `r10` is a different frame.

### PDA-signed CPIs

For both take_offer and cancel_offer the second Transfer CPI draws tokens from the vault, which is owned by the escrow PDA. The escrow PDA must sign. The program builds four `SolSignerSeed` entries on the stack, then points a `SolSignerSeeds` struct at them.

Seed 0 is the literal string `"escrow"` (6 bytes), written byte-by-byte. Seed 1 is the maker pubkey, copied from the escrow data with `copy32`. Seed 2 is the nonce, an 8-byte little-endian integer read from `ES_NONCE` in escrow data. Seed 3 is the single-byte bump, read from `ES_BUMP`. The order and lengths must match exactly what `find_program_address` would produce at derivation time.

## Building

```bash
sbpf build
```

This assembles `src/assembly_token_transfer/assembly_token_transfer.s` and writes the ELF to `deploy/assembly_token_transfer.so`.

The Makefile also has a `build` target that calls `llvm-mc` directly:

```bash
make build
```

## Running instructions

Each instruction has a JSON input file under `src/assembly_token_transfer/`. The file describes the full account state the runtime will present to the program — keys, owners, lamports, and data — along with the instruction data bytes.

```bash
make run-make     # executes make_offer against instructions.json
make run-take     # executes take_offer against instructions_take.json
make run-cancel   # executes cancel_offer against instructions_cancel.json
make run          # all three in sequence
```

Or directly with agave-ledger-tool:

```bash
agave-ledger-tool program run deploy/assembly_token_transfer.so \
    --ledger test-ledger \
    --mode interpreter \
    --input src/assembly_token_transfer/instructions_cancel.json \
    --trace trace_cancel.txt
```

The `--mode interpreter` flag runs the program through the SBF interpreter rather than JIT, which enables instruction-level tracing.

## Input files

Each JSON input has two top-level fields: `accounts` and `instruction_data`.

`accounts` is an ordered list of account objects. The order matches the account indices the program expects — index 0 is the first account the handler looks up at `r10-8`. Each account carries its pubkey, owner, lamports, executable flag, and raw data bytes. Token account data encodes the SPL Token layout: mint at offset 0 (32 bytes), owner at 32 (32 bytes), amount at 64 (8 bytes). Escrow account data encodes the layout described above — state byte, bump, nonce, maker pubkey, mint A, mint B, amount A, amount B, vault ATA pubkey.

`instruction_data` is the raw byte array passed to the program. The first byte is the discriminator: 0 for make_offer, 1 for take_offer, 2 for cancel_offer. make_offer also carries bump (1 byte), nonce (8 bytes little-endian), amount_a (8 bytes), and amount_b (8 bytes). take_offer and cancel_offer carry only the discriminator — all other data they need is read from the escrow account.

The input files represent account state at the moment the instruction is called, not genesis state. `instructions_take.json` shows the escrow already Active with all fields written, the vault already holding token A, and taker accounts funded and ready. `instructions_cancel.json` shows the same escrow with vault tokens intact and the maker's ATA empty.

## Tracing

With `--trace <file>`, agave-ledger-tool writes a line per instruction executed. Each line shows the program counter, the eBPF opcode, source/destination registers, and register values before the instruction runs:

```
0: ldxdw r6, [r1+0x0]                  r0=0x0 r1=0x400000020 r6=0x0 ...
1: mov64 r7, r1                         r6=0x5 ...
2: add64 r7, 0x8                        r7=0x400000020 ...
```

This is useful for verifying the account-walk loop produces the right strides, checking that CPI struct fields land at the expected stack addresses, and confirming the PDA seeds are assembled correctly before `sol_invoke_signed_c`. The first three lines always show the entrypoint loading `num_accounts` into `r6` and setting `r7` to the first account base. Watching `r7` advance through the loop confirms the stride arithmetic. A mismatch between the expected and actual `r7` at `find_ix_data_done` means a stride was computed wrong — usually a data_len alignment mistake.

## Tests

```bash
make test
# or
cargo test
```

Tests use [mollusk-svm](https://github.com/buffalojoec/mollusk), a lightweight SVM harness that runs the program in-process. Each instruction has a success test and failure tests for every validation the program performs — wrong signer, wrong owner, wrong escrow size, wrong mint, vault mismatch, wrong account count, and so on.

## Statistics

The deployed binary is 6584 bytes. The `.text` section is 5528 bytes — 691 eBPF instructions at 8 bytes each. No rodata, no BSS. The rest of the ELF is dynamic linking metadata required by the loader.

Compute unit consumption measured under mollusk-svm with the SPL Token program present:

| Instruction  | CU  | CPIs |
|--------------|-----|------|
| make_offer   | 1528 | 1 (maker → vault, maker signs) |
| take_offer   | 2863 | 2 (taker → maker, escrow PDA → taker) |
| cancel_offer | 1506 | 1 (escrow PDA → maker) |

The take_offer count is higher because it issues two CPIs and builds the full set of signer seeds twice — once for the unsigned transfer and once for the PDA-signed one. All three instructions stay well under 1% of the 1,400,000 CU budget.
