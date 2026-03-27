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
.equ SOL_ACCT_META_SIZE,  16   ; pubkey_ptr:8 + is_writable:1 + is_signer:1
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
    ; stride(d) = 96 + align8(d + 10240), where align8(n) = (n+7) & ~7
    ; r6 = num_accounts counter, r7 = current account ptr, r9 = save index
    ldxdw r6, [r1 + 0]         ; r6 = num_accounts
    mov64 r7, r1
    add64 r7, 8                ; r7 = first account base

find_ix_data_loop:
    jeq   r6, 0, find_ix_data_done

    ; save current account ptr at stack[r9] = [r10 - 8 - r9*8]
    mov64 r3, r9
    lsh64 r3, 3                ; r3 = r9 * 8
    mov64 r2, r10
    sub64 r2, 8
    sub64 r2, r3
    stxdw [r2 + 0], r7         ; stack[r9] = account base
    add64 r9, 1

    ldxdw r2, [r7 + ACCT_DLEN] ; r2 = data_len
    add64 r2, 10240            ; + MAX_PERMITTED_DATA_INCREASE
    add64 r2, 7                ; prepare ceiling-align
    mov64 r3, r2
    and64 r3, 7                ; r3 = low 3 bits
    sub64 r2, r3               ; align8(dlen + 10240)
    add64 r2, 96               ; + 88 fixed fields + 8 rent
    add64 r7, r2               ; advance to next account base
    sub64 r6, 1
    ja    find_ix_data_loop

find_ix_data_done:
    ldxdw r3, [r7 + 0]
    jlt   r3, 1, error_invalid_ix

    ldxb  r4, [r7 + 8]         ; discriminator

    jeq   r4, IX_MAKE_OFFER,   make_offer
    jeq   r4, IX_TAKE_OFFER,   take_offer
    jeq   r4, IX_CANCEL_OFFER, cancel_offer
    ja    error_invalid_ix

make_offer:
    ; account count >= 7
    ldxdw r2, [r1 + NUM_ACCOUNTS]
    jlt r2, 7, error_wrong_accounts_number

    ; maker (acct0) is signer
    ldxdw r2, [r10 - 8]
    ldxb r2, [r2 + ACCT_IS_SIGNER]
    jne r2, 1, error_no_signer

    ; escrow.owner == program_id
    ldxdw r3, [r7 + 0]
    mov64 r1, r7
    add64 r1, 8
    add64 r1, r3               ; r1 = &program_id
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_OWNER       ; r2 = &escrow.owner
    call cmp32
    jne r0, 0, error_escrow_owner

    ; escrow state == Active (fresh)
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    ldxb r3, [r2 + ES_STATE]
    jne r3, 0, error_es_state_not_fresh

    ; escrow dlen == ES_SIZE
    ldxdw r2, [r10 - 32]
    ldxdw r2, [r2 + ACCT_DLEN]
    jne r2, ES_SIZE, error_escrow_size

    ; a_amount > 0
    ldxdw r2, [r7 + 18]
    jeq r2, 0, error_invalid_amount

    ; maker_ata_a.owner == maker.key
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_OWNER
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY
    call cmp32
    jne r0, 0, error_maker_ata_owner

    ; maker_ata_a.mint == mint_a.key
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA        ; TOKEN_ACCT_MINT=0
    ldxdw r2, [r10 - 40]
    add64 r2, ACCT_KEY
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; vault_ata.mint == mint_a.key
    ldxdw r1, [r10 - 24]
    add64 r1, ACCT_DATA
    ldxdw r2, [r10 - 40]
    add64 r2, ACCT_KEY
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; ── save ix_data to stack ─────────────────────────
    ; ix_data layout: [disc:1, bump:1, nonce:8, a_amount:8, b_amount:8]
    ldxb r2, [r7 + 9]
    stxb [r10 - 81], r2        ; bump
    ldxdw r2, [r7 + 10]
    stxdw [r10 - 80], r2       ; nonce
    ldxdw r2, [r7 + 18]
    stxdw [r10 - 64], r2       ; a_amount
    ldxdw r2, [r7 + 26]
    stxdw [r10 - 72], r2       ; b_amount

    ; ── CPI: SPL Token Transfer(maker_ata_a → vault_ata, authority=maker) ──
    ; stack layout (all 8-byte aligned):
    ;   r10-104 : ix_data [disc:1, amount:8]
    ;   r10-152 : meta[0..2]  (16 bytes each)
    ;   r10-208 : SolInstruction
    ;   r10-384 : SolAccountInfo[0..2]  (56 bytes each)

    ; ix data [disc:1, amount:8]
    mov64 r2, TOKEN_TRANSFER_DISC
    stxb  [r10 - 104], r2
    ldxdw r2, [r10 - 64]       ; a_amount
    stxdw [r10 - 103], r2

    ; meta[0] maker_ata_a {key_ptr, writable=1, signer=0}
    ldxdw r2, [r10 - 16]
    add64 r2, ACCT_KEY
    stxdw [r10 - 152], r2      ; key_ptr
    mov64 r2, 1
    stxb  [r10 - 144], r2      ; is_writable
    mov64 r2, 0
    stxb  [r10 - 143], r2      ; is_signer

    ; meta[1] vault_ata {key_ptr, writable=1, signer=0}
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_KEY
    stxdw [r10 - 136], r2      ; key_ptr
    mov64 r2, 1
    stxb  [r10 - 128], r2      ; is_writable
    mov64 r2, 0
    stxb  [r10 - 127], r2      ; is_signer

    ; meta[2] maker {key_ptr, writable=0, signer=1}
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY
    stxdw [r10 - 120], r2      ; key_ptr
    mov64 r2, 0
    stxb  [r10 - 112], r2      ; is_writable
    mov64 r2, 1
    stxb  [r10 - 111], r2      ; is_signer

    ; SolInstruction
    ldxdw r2, [r10 - 56]
    add64 r2, ACCT_KEY
    stxdw [r10 - 208], r2      ; program_id ptr (token_program, acct6)
    mov64 r2, r10
    sub64 r2, 152
    stxdw [r10 - 200], r2      ; accounts_ptr → meta[0] at r10-152
    mov64 r2, 3
    stxdw [r10 - 192], r2      ; accounts_len
    mov64 r2, r10
    sub64 r2, 104
    stxdw [r10 - 184], r2      ; data_ptr → ix_data at r10-104
    mov64 r2, 9
    stxdw [r10 - 176], r2      ; data_len

    ; SolAccountInfo[0] = maker_ata_a (acct1)
    ldxdw r2, [r10 - 16]
    add64 r2, ACCT_KEY
    stxdw [r10 - 384 + 0], r2  ; key ptr
    ldxdw r2, [r10 - 16]
    add64 r2, ACCT_LAMPORTS
    stxdw [r10 - 384 + 8], r2  ; lamports ptr
    ldxdw r2, [r10 - 16]
    ldxdw r3, [r2 + ACCT_DLEN]
    stxdw [r10 - 384 + 16], r3 ; data_len value
    ldxdw r2, [r10 - 16]
    add64 r2, ACCT_DATA
    stxdw [r10 - 384 + 24], r2 ; data ptr
    ldxdw r2, [r10 - 16]
    add64 r2, ACCT_OWNER
    stxdw [r10 - 384 + 32], r2 ; owner ptr
    ldxdw r2, [r10 - 24]
    ldxdw r3, [r2 - 8]
    stxdw [r10 - 384 + 40], r3 ; rent_epoch (acct2_base - 8)
    mov64 r2, 0
    stxb  [r10 - 384 + 48], r2 ; is_signer=0
    mov64 r2, 1
    stxb  [r10 - 384 + 49], r2 ; is_writable=1
    mov64 r2, 0
    stxb  [r10 - 384 + 50], r2 ; is_executable=0

    ; SolAccountInfo[1] = vault_ata (acct2)
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_KEY
    stxdw [r10 - 328 + 0], r2  ; key ptr
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_LAMPORTS
    stxdw [r10 - 328 + 8], r2  ; lamports ptr
    ldxdw r2, [r10 - 24]
    ldxdw r3, [r2 + ACCT_DLEN]
    stxdw [r10 - 328 + 16], r3 ; data_len value
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_DATA
    stxdw [r10 - 328 + 24], r2 ; data ptr
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_OWNER
    stxdw [r10 - 328 + 32], r2 ; owner ptr
    ldxdw r2, [r10 - 32]
    ldxdw r3, [r2 - 8]
    stxdw [r10 - 328 + 40], r3 ; rent_epoch (acct3_base - 8)
    mov64 r2, 0
    stxb  [r10 - 328 + 48], r2 ; is_signer=0
    mov64 r2, 1
    stxb  [r10 - 328 + 49], r2 ; is_writable=1
    mov64 r2, 0
    stxb  [r10 - 328 + 50], r2 ; is_executable=0

    ; SolAccountInfo[2] = maker (acct0, authority)
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY
    stxdw [r10 - 272 + 0], r2  ; key ptr
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_LAMPORTS
    stxdw [r10 - 272 + 8], r2  ; lamports ptr
    ldxdw r2, [r10 - 8]
    ldxdw r3, [r2 + ACCT_DLEN]
    stxdw [r10 - 272 + 16], r3 ; data_len value
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_DATA
    stxdw [r10 - 272 + 24], r2 ; data ptr
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_OWNER
    stxdw [r10 - 272 + 32], r2 ; owner ptr
    ldxdw r2, [r10 - 16]
    ldxdw r3, [r2 - 8]
    stxdw [r10 - 272 + 40], r3 ; rent_epoch (acct1_base - 8)
    mov64 r2, 1
    stxb  [r10 - 272 + 48], r2 ; is_signer=1
    mov64 r2, 1
    stxb  [r10 - 272 + 49], r2 ; is_writable=1
    mov64 r2, 0
    stxb  [r10 - 272 + 50], r2 ; is_executable=0

    ; CPI call
    mov64 r1, r10
    sub64 r1, 208              ; &SolInstruction  (208%8=0 ✓)
    mov64 r2, r10
    sub64 r2, 384              ; &SolAccountInfo[0]  (384%8=0 ✓)
    mov64 r3, 3
    mov64 r4, 0
    mov64 r5, 0
    call sol_invoke_signed_c
    jne r0, 0, error_cpi_failed

    ; ── write escrow state ────────────────────────────
    ldxdw r6, [r10 - 32]
    add64 r6, ACCT_DATA        ; r6 = &escrow.data[0], preserved across copy32 calls

    mov64 r2, STATE_ACTIVE
    stxb  [r6 + ES_STATE], r2   ; state = Active
    ldxb  r2, [r10 - 81]
    stxb  [r6 + ES_BUMP], r2    ; bump
    ldxdw r2, [r10 - 80]
    stxdw [r6 + ES_NONCE], r2   ; nonce
    ldxdw r2, [r10 - 64]
    stxdw [r6 + ES_AMOUNT_A], r2 ; amount_a
    ldxdw r2, [r10 - 72]
    stxdw [r6 + ES_AMOUNT_B], r2 ; amount_b

    ; ES_MAKER = acct0.key
    mov64 r1, r6
    add64 r1, ES_MAKER
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY
    call copy32

    ; ES_MINT_A = acct4.key
    mov64 r1, r6
    add64 r1, ES_MINT_A
    ldxdw r2, [r10 - 40]
    add64 r2, ACCT_KEY
    call copy32

    ; ES_MINT_B = acct5.key
    mov64 r1, r6
    add64 r1, ES_MINT_B
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_KEY
    call copy32

    ; ES_VAULT_ATA = acct2.key
    mov64 r1, r6
    add64 r1, ES_VAULT_ATA
    ldxdw r2, [r10 - 24]
    add64 r2, ACCT_KEY
    call copy32

    mov64 r0, 0
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

error_wrong_accounts_number:
    mov64 r0, 0x02
    exit

error_no_signer:
    mov64 r0, 0x03
    exit

error_escrow_owner:
    mov64 r0, 0x04
    exit

error_es_state_not_fresh:
    mov64 r0, 0x05
    exit

error_cpi_failed:
    mov64 r0, 0x06
    exit

error_escrow_size:
    mov64 r0, 0x07
    exit

error_invalid_amount:
    mov64 r0, 0x08
    exit

error_maker_ata_owner:
    mov64 r0, 0x09
    exit

error_mint_mismatch:
    mov64 r0, 0x0A
    exit

; ── Helpers ───────────────────────────────────────────
; cmp32: r1=ptr_a, r2=ptr_b → r0=0 equal, r0=1 not-equal
; clobbers r3, r4
cmp32:
    ldxdw r3, [r1 + 0]
    ldxdw r4, [r2 + 0]
    jne r3, r4, cmp32_ne
    ldxdw r3, [r1 + 8]
    ldxdw r4, [r2 + 8]
    jne r3, r4, cmp32_ne
    ldxdw r3, [r1 + 16]
    ldxdw r4, [r2 + 16]
    jne r3, r4, cmp32_ne
    ldxdw r3, [r1 + 24]
    ldxdw r4, [r2 + 24]
    jne r3, r4, cmp32_ne
    mov64 r0, 0
    exit
cmp32_ne:
    mov64 r0, 1
    exit

; copy32: r1=dst, r2=src — clobbers r3
copy32:
    ldxdw r3, [r2 + 0]
    stxdw [r1 + 0], r3
    ldxdw r3, [r2 + 8]
    stxdw [r1 + 8], r3
    ldxdw r3, [r2 + 16]
    stxdw [r1 + 16], r3
    ldxdw r3, [r2 + 24]
    stxdw [r1 + 24], r3
    exit
