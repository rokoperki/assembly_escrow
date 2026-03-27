; ── Input buffer ─────────────────────────────────────
.equ NUM_ACCOUNTS,    0x0000   ; u64 at r1+0
.equ FIRST_ACCT,      0x0008   ; first account base
.equ ACCT_STRIDE,     0x2860   ; bytes per account slot

; ── Per-account fields (offset from account base) ────
.equ ACCT_DUP,        0x00     ; u8 dup_info (0xff = not dup)
.equ ACCT_IS_SIGNER,  0x01     ; u8
.equ ACCT_IS_WRITE,   0x02     ; u8
.equ ACCT_EXEC,       0x03     ; u8
.equ ACCT_KEY,        0x08     ; [u8;32] pubkey
.equ ACCT_OWNER,      0x28     ; [u8;32] owner program
.equ ACCT_LAMPORTS,   0x48     ; u64
.equ ACCT_DLEN,       0x50     ; u64 data length
.equ ACCT_DATA,       0x58     ; data start
.equ ACCT_RENT,       0x2858   ; u64 rent_epoch

; ── After accounts in buffer ─────────────────────────
; ix_data_len: u64  found by walking accounts (stride varies by data_len)
; ix_data:     u8[] at ix_data_len_ptr + 8
; stride(d)  = 96 + align8(d + 10240)  where align8(n) = (n+7) & ~7

; ── SPL Token account data offsets (within acct.data) ─
.equ TOKEN_ACCT_MINT,   0x00   ; [u8;32]
.equ TOKEN_ACCT_OWNER,  0x20   ; [u8;32]
.equ TOKEN_ACCT_AMOUNT, 0x40   ; u64

; ── Escrow state offsets (within escrow_state.data) ───
.equ ES_STATE,          0x00   ; u8  0=Active 1=Complete 2=Cancel
.equ ES_BUMP,           0x01   ; u8
.equ ES_NONCE,          0x02   ; u64
.equ ES_MAKER,          0x0A   ; [u8;32]
.equ ES_MINT_A,         0x2A   ; [u8;32]
.equ ES_MINT_B,         0x4A   ; [u8;32]
.equ ES_AMOUNT_A,       0x6A   ; u64
.equ ES_AMOUNT_B,       0x72   ; u64
.equ ES_VAULT_ATA,      0x7A   ; [u8;32]
.equ ES_SIZE,           0x9A   ; 154 bytes total

; ── Instruction discriminators ───────────────────────
.equ IX_MAKE_OFFER,     0
.equ IX_TAKE_OFFER,     1
.equ IX_CANCEL_OFFER,   2

; ── State values ─────────────────────────────────────
.equ STATE_ACTIVE,      0
.equ STATE_COMPLETED,   1
.equ STATE_CANCELLED,   2

; ── SPL Token ─────────────────────────────────────────
.equ TOKEN_TRANSFER_DISC, 3    ; u8 discriminator for Transfer ix

; ── CPI struct sizes (bytes) ─────────────────────────
.equ SOL_ACCT_META_SIZE,  24   ; pubkey_ptr:8 + is_writable:8 + is_signer:8
.equ SOL_INSTRUCTION_SIZE,40   ; prog_ptr:8 + accts_ptr:8 + accts_len:8 + data_ptr:8 + data_len:8
.equ SOL_SIGNER_SEED_SIZE,16   ; ptr:8 + len:8
.equ SOL_SIGNER_SIZE,     16   ; seeds_ptr:8 + seeds_len:8

; ── PDA seed lengths ─────────────────────────────────
.equ SEED_ESCROW_LEN,    6     ; "escrow"
.equ SEED_PUBKEY_LEN,   32
.equ SEED_NONCE_LEN,     8
.equ SEED_BUMP_LEN,      1


.globl entrypoint


entrypoint:
    ; ── find ix_data by walking accounts dynamically ──────
    ; stride(data_len) = 96 + align8(data_len + 10240)
    ; where align8(n) = (n + 7) & ~7
    ;
    ; r6 = num_accounts (counter)
    ; r7 = walking pointer (account base)
    ; r8 = r1 (saved input buffer base)
    mov64 r8, r1
    ldxdw r6, [r1 + 0]         ; r6 = num_accounts
    mov64 r7, r1
    add64 r7, 8                ; r7 = first account base

find_ix_data_loop:
    jeq   r6, 0, find_ix_data_done
    ldxdw r2, [r7 + ACCT_DLEN] ; r2 = this account's data_len
    add64 r2, 10240            ; r2 = data_len + MAX_PERMITTED_DATA_INCREASE
    add64 r2, 7                ; prepare ceiling-align to 8
    mov64 r3, r2
    and64 r3, 7                ; r3 = low 3 bits
    sub64 r2, r3               ; r2 = align8(data_len + 10240)
    add64 r2, 96               ; + 88 fixed fields + 8 rent = 96
    add64 r7, r2               ; advance to next account base
    sub64 r6, 1
    ja    find_ix_data_loop

find_ix_data_done:
    ldxdw r3, [r7 + 0]
    jlt   r3, 1, error_invalid_ix

    ldxb  r4, [r7 + 8]         ; r4 = discriminator

    jeq   r4, IX_MAKE_OFFER,   make_offer
    jeq   r4, IX_TAKE_OFFER,   take_offer
    jeq   r4, IX_CANCEL_OFFER, cancel_offer
    ja    error_invalid_ix

make_offer:
  ldxdw r2, [r1 + NUM_ACCOUNTS]
  exit

take_offer:
  ldxdw r2, [r1 + NUM_ACCOUNTS]
  exit

cancel_offer:
  ldxdw r2, [r1 + NUM_ACCOUNTS]
  exit

error_invalid_ix:
    mov64 r0, 0x01
    exit
