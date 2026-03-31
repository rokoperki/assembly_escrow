# assembly_token_transfer

A two-party token escrow on Solana in raw sBPF assembly. No Rust, no Anchor — just instructions.

## What it does

The maker deposits token A into a vault and names a price in token B. The taker pays and receives token A atomically. If the maker changes their mind, they cancel and get tokens back.

Three instructions:

- **make_offer** — transfers token A into a PDA-owned vault, writes escrow state (maker, mints, amounts, vault) to an escrow account
- **take_offer** — two CPIs: taker pays token B to maker, escrow PDA releases token A to taker
- **cancel_offer** — escrow PDA returns vaulted token A to maker, sets state to Cancelled

The escrow PDA is derived from `["escrow", maker_pubkey, nonce_le64]`. The nonce allows concurrent escrows per maker. Bump is stored in escrow data at offset 1 and used directly in PDA-signed CPIs.

## Assembly

**Input buffer.** Accounts are not fixed-stride. Each slot is `96 + align8(dlen + 10240)` bytes. The entrypoint walks all accounts in a loop, saves each base pointer to a stack slot (`r10-8` = acct0, `r10-16` = acct1, …), and lands on the instruction data right after the last account.

**Registers.** `r1`–`r5` are clobbered by any `call`. `r6`–`r9` survive calls and hold values that must outlast a CPI. `r10` is the frame pointer. After each CPI, account pointers are reloaded from their stack slots.

**CPI structs.** `SolAccountMeta` (16 B), `SolInstruction` (40 B), `SolAccountInfo` (56 B), `SolSignerSeed` (16 B), and `SolSignerSeeds` (16 B) are all built by hand on the stack before each `sol_invoke_signed_c`. Pointer fields point directly into the runtime-provided input buffer — no copies. `rent_epoch` is read as `*(next_account_base - 8)` since it sits at the end of each account slot.

**Helpers.** `fill_meta` and `fill_acct_info` take an explicit destination pointer because each `call` frame has its own `r10`. `cmp32` and `copy32` compare or copy 32-byte pubkeys in four 8-byte loads/stores.

**Escrow layout** (154 bytes):

```
+0x00  state      u8    0=Active 1=Complete 2=Cancelled
+0x01  bump       u8
+0x02  nonce      u64
+0x0A  maker     [u8;32]
+0x2A  mint_a    [u8;32]
+0x4A  mint_b    [u8;32]
+0x6A  amount_a   u64
+0x72  amount_b   u64
+0x7A  vault_ata [u8;32]
```

## Build

```bash
sbpf build
```

Assembles `src/assembly_token_transfer/assembly_token_transfer.s` → `deploy/assembly_token_transfer.so`.

## Run

```bash
make run-make     # make_offer
make run-take     # take_offer
make run-cancel   # cancel_offer
make run          # all three
```

Uses `agave-ledger-tool` with `--mode interpreter`. Each run writes a trace file (`trace_make.txt.0`, etc. — agave appends `.0`).

Each trace line shows all 11 registers before the instruction executes, followed by the PC and opcode:

```
3 [r0..r9, r10]  3: jeq r6, 0, lbb_21
```

Full example from the entrypoint account walk:

```
0 [..., r1=0x400000000, ..., r6=0x0,         r7=0x0,          ..., r10=0x200001000]  0: ldxdw r6, [r1+0x0]
1 [..., r1=0x400000000, ..., r6=0x7,         r7=0x0,          ..., r10=0x200001000]  1: mov64 r7, r1
2 [..., r1=0x400000000, ..., r6=0x7,         r7=0x400000000,  ..., r10=0x200001000]  2: add64 r7, 8
3 [..., r1=0x400000000, ..., r6=0x7,         r7=0x400000008,  ..., r10=0x200001000]  3: jeq r6, 0, ...
```

After line 0, `r6 = 7` (num_accounts). After line 2, `r7 = input_base + 8` (first account base). Watching `r7` advance each loop iteration confirms the stride arithmetic. Checking `r10-8`, `r10-16`, … after the loop confirms the saved account pointers. Before a `sol_invoke_signed_c` call, the register dump shows the exact addresses of the `SolInstruction` and `SolAccountInfo` structs — cross-reference against the stack layout comments in the source to verify nothing overlaps.

## Test

```bash
make test
```

Uses [mollusk-svm](https://github.com/buffalojoec/mollusk). Each instruction has a success test and failure tests for every validation path.

## Input files

JSON files under `src/assembly_token_transfer/`. Each has `accounts` (ordered list matching program account indices) and `instruction_data` (raw bytes). Discriminator is the first byte: `0` = make, `1` = take, `2` = cancel. make_offer also carries bump, nonce, amount_a, amount_b. The other two read all needed data from the escrow account.

## Statistics

Binary: 6584 bytes total, 5528 bytes `.text` (691 instructions × 8 bytes).

| Instruction  | CU   | CPIs |
|--------------|------|------|
| make_offer   | 1528 | 1    |
| take_offer   | 2863 | 2    |
| cancel_offer | 1506 | 1    |

All three stay under 1% of the 1,400,000 CU budget.
