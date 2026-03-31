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
    ; account count == 7
    ldxdw r2, [r1 + NUM_ACCOUNTS]
    jne r2, 7, error_wrong_accounts_number

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

    ; meta[0] maker_ata_a {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 152
    ldxdw r2, [r10 - 16]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[1] vault_ata {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 136
    ldxdw r2, [r10 - 24]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[2] maker {writable=0, signer=1}
    mov64 r1, r10
    sub64 r1, 120
    ldxdw r2, [r10 - 8]
    mov64 r3, 0
    mov64 r4, 1
    call fill_meta

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
    mov64 r1, r10
    sub64 r1, 384
    ldxdw r2, [r10 - 16]
    ldxdw r3, [r10 - 24]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[1] = vault_ata (acct2)
    mov64 r1, r10
    sub64 r1, 328
    ldxdw r2, [r10 - 24]
    ldxdw r3, [r10 - 32]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[2] = maker (acct0, authority)
    mov64 r1, r10
    sub64 r1, 272
    ldxdw r2, [r10 - 8]
    ldxdw r3, [r10 - 16]
    mov64 r4, 1
    mov64 r5, 1
    call fill_acct_info

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
    ; account count == 9
    ldxdw r2, [r1 + NUM_ACCOUNTS]
    jne r2, 9, error_wrong_accounts_number

    ; taker (acct0) is signer
    ldxdw r2, [r10 - 8]
    ldxb r2, [r2 + ACCT_IS_SIGNER]
    jne r2, 1, error_no_signer

    ; escrow.owner (acct5) == program_id
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_OWNER       ; r2 = &escrow.owner
    ldxdw r3, [r7 + 0]
    mov64 r1, r7
    add64 r1, 8
    add64 r1, r3               ; r1 = &program_id
    call cmp32
    jne r0, 0, error_escrow_owner

    ; escrow.state == Active (0)
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    ldxb r3, [r2 + ES_STATE]
    jne r3, 0, error_es_state_not_fresh

    ; escrow dlen == ES_SIZE
    ldxdw r2, [r10 - 48]
    ldxdw r2, [r2 + ACCT_DLEN]
    jne r2, ES_SIZE, error_escrow_size

    ; token_ata_b.mint == escrow.mint_b
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_MINT       ; r1 = &token_ata_b.mint_b
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_MINT_B             ; r2 = &escrow.mint_b
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; token_ata_b.owner == taker.key
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_OWNER      ; r1 = &token_ata_b.owner
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY              ; r2 = &taker.key
    call cmp32
    jne r0, 0, error_taker_ata_owner

    ; vault_ata.key == escrow.vault_ata
    ldxdw r1, [r10 - 32]
    add64 r1, ACCT_KEY          ; r1 = &vault_ata.key
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_VAULT_ATA       ; r2 = &escrow.vault_ata
    call cmp32
    jne r0, 0, error_vault_ata_mismatch

    ; maker_ata_b.owner == escrow.maker
    ldxdw r1, [r10 - 24]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_OWNER      ; r1 = &maker_ata_b.owner
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_MAKER              ; r2 = &escrow.maker
    call cmp32
    jne r0, 0, error_maker_atab_owner

    ; maker_ata_b.mint == escrow.mint_b
    ldxdw r1, [r10 - 24]
    add64 r1, ACCT_DATA             ; TOKEN_ACCT_MINT=0
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_MINT_B             ; r2 = &escrow.mint_b
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; taker_ata_a.mint == escrow.mint_a
    ldxdw r1, [r10 - 40]
    add64 r1, ACCT_DATA             ; TOKEN_ACCT_MINT=0
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_MINT_A             ; r2 = &escrow.mint_a
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; taker_ata_a.owner == taker.key
    ldxdw r1, [r10 - 40]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_OWNER      ; r1 = &taker_ata_a.owner
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY              ; r2 = &taker.key
    call cmp32
    jne r0, 0, error_taker_ata_owner

    ; ix data [disc:1, amount:8]
    mov64 r2, TOKEN_TRANSFER_DISC
    stxb  [r10 - 82], r2
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    ldxdw r2, [r2 + ES_AMOUNT_B]
    stxdw [r10 - 81], r2            ; b_amount

    ; meta[0] taker_ata_b {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 128
    ldxdw r2, [r10 - 16]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[1] maker_ata_b {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 112
    ldxdw r2, [r10 - 24]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[2] taker {writable=0, signer=1}
    mov64 r1, r10
    sub64 r1, 96
    ldxdw r2, [r10 - 8]
    mov64 r3, 0
    mov64 r4, 1
    call fill_meta

    ; SolInstruction
    ldxdw r2, [r10 - 72]
    add64 r2, ACCT_KEY
    stxdw [r10 - 184], r2      ; program_id ptr (token_program, acct8)
    mov64 r2, r10
    sub64 r2, 128
    stxdw [r10 - 176], r2      ; accounts_ptr → meta[0] at r10-152
    mov64 r2, 3
    stxdw [r10 - 168], r2      ; accounts_len
    mov64 r2, r10
    sub64 r2, 82
    stxdw [r10 - 160], r2      ; data_ptr → ix_data at r10-82
    mov64 r2, 9
    stxdw [r10 - 152], r2      ; data_len

    ; SolAccountInfo[0] = taker_ata_b (acct1)
    mov64 r1, r10
    sub64 r1, 360
    ldxdw r2, [r10 - 16]
    ldxdw r3, [r10 - 24]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[1] = maker_ata_b (acct2)
    mov64 r1, r10
    sub64 r1, 304
    ldxdw r2, [r10 - 24]
    ldxdw r3, [r10 - 32]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[2] = taker (acct0, authority)
    mov64 r1, r10
    sub64 r1, 248
    ldxdw r2, [r10 - 8]
    ldxdw r3, [r10 - 16]
    mov64 r4, 1
    mov64 r5, 0
    call fill_acct_info

    ; taker_ata_b -> maker_ata_b CPI call
    mov64 r1, r10
    sub64 r1, 184              ; &SolInstruction
    mov64 r2, r10
    sub64 r2, 360              ; &SolAccountInfo[0]
    mov64 r3, 3
    mov64 r4, 0
    mov64 r5, 0
    call sol_invoke_signed_c
    jne r0, 0, error_cpi_failed

    ; ix data [disc:1, amount:8]
    mov64 r2, TOKEN_TRANSFER_DISC
    stxb  [r10 - 82], r2
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    ldxdw r2, [r2 + ES_AMOUNT_A]
    stxdw [r10 - 81], r2            ; a_amount

    ; meta[0] vault_ata {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 128
    ldxdw r2, [r10 - 32]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[1] taker_ata_a {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 112
    ldxdw r2, [r10 - 40]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[2] escrow {writable=0, signer=1}
    mov64 r1, r10
    sub64 r1, 96
    ldxdw r2, [r10 - 48]
    mov64 r3, 0
    mov64 r4, 1
    call fill_meta

    ; SolInstruction
    ldxdw r2, [r10 - 72]
    add64 r2, ACCT_KEY
    stxdw [r10 - 184], r2      ; program_id ptr (token_program, acct8)
    mov64 r2, r10
    sub64 r2, 128
    stxdw [r10 - 176], r2      ; accounts_ptr → meta[0] at r10-128
    mov64 r2, 3
    stxdw [r10 - 168], r2      ; accounts_len
    mov64 r2, r10
    sub64 r2, 82
    stxdw [r10 - 160], r2      ; data_ptr → ix_data at r10-82
    mov64 r2, 9
    stxdw [r10 - 152], r2      ; data_len

    ; SolAccountInfo[0] = vault_ata (acct3)
    mov64 r1, r10
    sub64 r1, 360
    ldxdw r2, [r10 - 32]
    ldxdw r3, [r10 - 40]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[1] = taker_ata_a (acct4)
    mov64 r1, r10
    sub64 r1, 304
    ldxdw r2, [r10 - 40]
    ldxdw r3, [r10 - 48]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[2] = escrow (acct5, authority)
    mov64 r1, r10
    sub64 r1, 248
    ldxdw r2, [r10 - 48]
    ldxdw r3, [r10 - 56]
    mov64 r4, 1
    mov64 r5, 0
    call fill_acct_info

    ; ── seed bytes ────────────────────────────────────────
    ; bump at r10-362
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    ldxb  r3, [r2 + ES_BUMP]
    stxb  [r10 - 362], r3

    ; "escrow" at r10-368..r10-363
    mov64 r3, 0x65               ; 'e'
    stxb  [r10 - 368], r3
    mov64 r3, 0x73               ; 's'
    stxb  [r10 - 367], r3
    mov64 r3, 0x63               ; 'c'
    stxb  [r10 - 366], r3
    mov64 r3, 0x72               ; 'r'
    stxb  [r10 - 365], r3
    mov64 r3, 0x6F               ; 'o'
    stxb  [r10 - 364], r3
    mov64 r3, 0x77               ; 'w'
    stxb  [r10 - 363], r3

    ; nonce at r10-376..r10-369
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    ldxdw r3, [r2 + ES_NONCE]
    stxdw [r10 - 376], r3

    ; maker key at r10-408..r10-377
    mov64 r1, r10
    sub64 r1, 408
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    add64 r2, ES_MAKER
    call copy32

    ; ── SolSignerSeed[4] ──────────────────────────────────
    ; seed[0] "escrow": ptr=r10-368, len=6
    mov64 r2, r10
    sub64 r2, 368
    stxdw [r10 - 472], r2
    mov64 r2, SEED_ESCROW_LEN
    stxdw [r10 - 464], r2

    ; seed[1] maker: ptr=r10-408, len=32
    mov64 r2, r10
    sub64 r2, 408
    stxdw [r10 - 456], r2
    mov64 r2, SEED_PUBKEY_LEN
    stxdw [r10 - 448], r2

    ; seed[2] nonce: ptr=r10-376, len=8
    mov64 r2, r10
    sub64 r2, 376
    stxdw [r10 - 440], r2
    mov64 r2, SEED_NONCE_LEN
    stxdw [r10 - 432], r2

    ; seed[3] bump: ptr=r10-362, len=1
    mov64 r2, r10
    sub64 r2, 362
    stxdw [r10 - 424], r2
    mov64 r2, SEED_BUMP_LEN
    stxdw [r10 - 416], r2

    ; ── SolSignerSeeds ────────────────────────────────────
    mov64 r2, r10
    sub64 r2, 472
    stxdw [r10 - 488], r2        ; seeds_ptr → seed[0]
    mov64 r2, 4
    stxdw [r10 - 480], r2        ; seeds_len

    ; ── CPI call ──────────────────────────────────────────
    mov64 r1, r10
    sub64 r1, 184                ; &SolInstruction
    mov64 r2, r10
    sub64 r2, 360                ; &SolAccountInfo[0]
    mov64 r3, 3
    mov64 r4, r10
    sub64 r4, 488                ; &SolSignerSeeds
    mov64 r5, 1
    call sol_invoke_signed_c
    jne r0, 0, error_cpi_failed

    ; ── escrow state = Completed ──────────────────────────
    ldxdw r2, [r10 - 48]
    add64 r2, ACCT_DATA
    mov64 r3, STATE_COMPLETED
    stxb  [r2 + ES_STATE], r3

    mov64 r0, 0
    exit

cancel_offer:

    ; num_account == 5
    ldxdw r2, [r1 + NUM_ACCOUNTS]
    jne r2, 5, error_wrong_accounts_number

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

    ; escrow.dlen == ES_SIZE
    ldxdw r2, [r10 - 32]
    ldxdw r2, [r2 + ACCT_DLEN]
    jne r2, ES_SIZE, error_escrow_size

    ; escrow.state == active
    ldxdw r2, [r10 - 32]
    ldxb r2, [r2 + ACCT_DATA + ES_STATE]
    jne r2, 0, error_es_state_not_fresh

    ; escrow.maker == maker (acct0)
    ldxdw r1, [r10 - 8]
    add64 r1, ACCT_KEY
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    add64 r2, ES_MAKER
    call cmp32
    jne r0, 0, error_maker_mismatch

    ; vault_ata.key == escrow.vault
    ldxdw r1, [r10 - 24]
    add64 r1, ACCT_KEY
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    add64 r2, ES_VAULT_ATA
    call cmp32
    jne r0, 0, error_vault_ata_mismatch

    ; maker_ata_a.mint == escrow.mint_a
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_MINT
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    add64 r2, ES_MINT_A
    call cmp32
    jne r0, 0, error_mint_mismatch

    ; maker_ata_a.owner == maker.key
    ldxdw r1, [r10 - 16]
    add64 r1, ACCT_DATA
    add64 r1, TOKEN_ACCT_OWNER
    ldxdw r2, [r10 - 8]
    add64 r2, ACCT_KEY
    call cmp32
    jne r0, 0, error_maker_ata_owner

    ; ix data [disc:1, amount:8]
    mov64 r2, TOKEN_TRANSFER_DISC
    stxb  [r10 - 56], r2
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    ldxdw r2, [r2 + ES_AMOUNT_A]
    stxdw [r10 - 55], r2            ; a_amount

    ; meta[0] vault_ata {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 104
    ldxdw r2, [r10 - 24]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[1] maker_ata_a {writable=1, signer=0}
    mov64 r1, r10
    sub64 r1, 88
    ldxdw r2, [r10 - 16]
    mov64 r3, 1
    mov64 r4, 0
    call fill_meta

    ; meta[2] escrow {writable=0, signer=1}
    mov64 r1, r10
    sub64 r1, 72
    ldxdw r2, [r10 - 32]
    mov64 r3, 0
    mov64 r4, 1
    call fill_meta

    ; SolInstruction
    ldxdw r2, [r10 - 40]
    add64 r2, ACCT_KEY
    stxdw [r10 - 152], r2      ; program_id ptr (token_program, acct4)
    mov64 r2, r10
    sub64 r2, 104
    stxdw [r10 - 144], r2      ; accounts_ptr → meta[0] at r10-104
    mov64 r2, 3
    stxdw [r10 - 136], r2      ; accounts_len
    mov64 r2, r10
    sub64 r2, 56
    stxdw [r10 - 128], r2      ; data_ptr → ix_data at r10-56
    mov64 r2, 9
    stxdw [r10 - 120], r2      ; data_len

    ; SolAccountInfo[0] = vault_ata (acct2)
    mov64 r1, r10
    sub64 r1, 328
    ldxdw r2, [r10 - 24]
    ldxdw r3, [r10 - 32]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[1] = maker_ata_a (acct1)
    mov64 r1, r10
    sub64 r1, 272
    ldxdw r2, [r10 - 16]
    ldxdw r3, [r10 - 24]
    mov64 r4, 0
    mov64 r5, 1
    call fill_acct_info

    ; SolAccountInfo[2] = escrow (acct3, authority)
    mov64 r1, r10
    sub64 r1, 216
    ldxdw r2, [r10 - 32]
    ldxdw r3, [r10 - 40]
    mov64 r4, 1
    mov64 r5, 0
    call fill_acct_info

    ; ── seed bytes ────────────────────────────────────────
    ; bump at r10-330
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    ldxb  r3, [r2 + ES_BUMP]
    stxb  [r10 - 330], r3

    ; "escrow" at r10-336..r10-331
    mov64 r3, 0x65               ; 'e'
    stxb  [r10 - 336], r3
    mov64 r3, 0x73               ; 's'
    stxb  [r10 - 335], r3
    mov64 r3, 0x63               ; 'c'
    stxb  [r10 - 334], r3
    mov64 r3, 0x72               ; 'r'
    stxb  [r10 - 333], r3
    mov64 r3, 0x6F               ; 'o'
    stxb  [r10 - 332], r3
    mov64 r3, 0x77               ; 'w'
    stxb  [r10 - 331], r3

    ; nonce at r10-344..r10-337
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    ldxdw r3, [r2 + ES_NONCE]
    stxdw [r10 - 344], r3

    ; maker key at r10-376..r10-345
    mov64 r1, r10
    sub64 r1, 376
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    add64 r2, ES_MAKER
    call copy32

    ; ── SolSignerSeed[4] ──────────────────────────────────
    ; seed[0] "escrow": ptr=r10-336, len=6
    mov64 r2, r10
    sub64 r2, 336
    stxdw [r10 - 472], r2
    mov64 r2, SEED_ESCROW_LEN
    stxdw [r10 - 464], r2

    ; seed[1] maker: ptr=r10-376, len=32
    mov64 r2, r10
    sub64 r2, 376
    stxdw [r10 - 456], r2
    mov64 r2, SEED_PUBKEY_LEN
    stxdw [r10 - 448], r2

    ; seed[2] nonce: ptr=r10-337, len=8
    mov64 r2, r10
    sub64 r2, 344
    stxdw [r10 - 440], r2
    mov64 r2, SEED_NONCE_LEN
    stxdw [r10 - 432], r2

    ; seed[3] bump: ptr=r10-330, len=1
    mov64 r2, r10
    sub64 r2, 330
    stxdw [r10 - 424], r2
    mov64 r2, SEED_BUMP_LEN
    stxdw [r10 - 416], r2


    ; ── SolSignerSeeds ────────────────────────────────────
    mov64 r2, r10
    sub64 r2, 472
    stxdw [r10 - 488], r2        ; seeds_ptr → seed[0]
    mov64 r2, 4
    stxdw [r10 - 480], r2        ; seeds_len

    ; ── CPI call ──────────────────────────────────────────
    mov64 r1, r10
    sub64 r1, 152                ; &SolInstruction
    mov64 r2, r10
    sub64 r2, 328                ; &SolAccountInfo[0]
    mov64 r3, 3
    mov64 r4, r10
    sub64 r4, 488                ; &SolSignerSeeds
    mov64 r5, 1
    call sol_invoke_signed_c
    jne r0, 0, error_cpi_failed

    ; ── escrow state = Cancelled ──────────────────────────
    ldxdw r2, [r10 - 32]
    add64 r2, ACCT_DATA
    mov64 r3, STATE_CANCELLED
    stxb  [r2 + ES_STATE], r3

    mov64 r0, 0
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

error_taker_ata_owner:
    mov64 r0, 0x0B
    exit

error_vault_ata_mismatch:
    mov64 r0, 0x0C
    exit

error_maker_atab_owner:
    mov64 r0, 0x0D
    exit

error_maker_mismatch:
    mov64 r0, 0x0E
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

; fill_meta: r1=dst, r2=acct_ptr, r3=is_writable, r4=is_signer
fill_meta:
    add64 r2, ACCT_KEY
    stxdw [r1 + 0], r2
    stxb  [r1 + 8], r3
    stxb  [r1 + 9], r4
    exit

; fill_acct_info: r1=dst, r2=acct_ptr, r3=next_acct_ptr, r4=is_signer, r5=is_writable
; uses r0 as scratch, does NOT touch r6-r9
fill_acct_info:
    mov64 r0, r2
    add64 r0, ACCT_KEY
    stxdw [r1 + 0], r0
    mov64 r0, r2
    add64 r0, ACCT_LAMPORTS
    stxdw [r1 + 8], r0
    ldxdw r0, [r2 + ACCT_DLEN]
    stxdw [r1 + 16], r0
    mov64 r0, r2
    add64 r0, ACCT_DATA
    stxdw [r1 + 24], r0
    mov64 r0, r2
    add64 r0, ACCT_OWNER
    stxdw [r1 + 32], r0
    ldxdw r0, [r3 - 8]
    stxdw [r1 + 40], r0
    stxb  [r1 + 48], r4
    stxb  [r1 + 49], r5
    mov64 r0, 0
    stxb  [r1 + 50], r0
    exit
