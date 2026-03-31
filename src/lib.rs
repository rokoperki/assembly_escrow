#[cfg(test)]
mod tests {
    use mollusk_svm::{program::loader_keys, result::Check, Mollusk};
    use solana_account::Account;
    use solana_address::Address;
    use solana_instruction::{AccountMeta, Instruction};
    use solana_program_error::ProgramError;

    fn address(base58: &str) -> Address {
        let bytes = bs58::decode(base58).into_vec().expect("valid base58");
        Address::new_from_array(bytes.try_into().expect("32 bytes"))
    }

    struct Fixture {
        program_id: Address,
        maker: Address,
        maker_ata_a: Address,
        vault_ata: Address,
        escrow: Address,
        mint_a: Address,
        mint_b: Address,
        token_prog: Address,
        system_prog: Address,
        instruction_data: Vec<u8>,
    }

    impl Fixture {
        fn new() -> Self {
            let program_id_bytes: [u8; 32] =
                std::fs::read("deploy/assembly_token_transfer-keypair.json").unwrap()[..32]
                    .try_into()
                    .unwrap();
            Self {
                program_id:  Address::new_from_array(program_id_bytes),
                maker:       address("524HMdYYBy6TAn4dK5vCcjiTmT2sxV6Xoue5EXrz22Ca"),
                maker_ata_a: address("7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2"),
                vault_ata:   address("GJRs4FwHtemZ5ZE9x3FNvJ8TMwitKTh21yxdRPqn7v5"),
                escrow:      address("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"),
                mint_a:      address("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
                mint_b:      address("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"),
                token_prog:  address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"),
                system_prog: address("11111111111111111111111111111111"),
                instruction_data: [
                    vec![0u8, 254u8],                   // disc=make_offer, bump=254
                    0u64.to_le_bytes().to_vec(),         // nonce=0
                    1_000_000u64.to_le_bytes().to_vec(), // a_amount=1_000_000
                    2_000_000u64.to_le_bytes().to_vec(), // b_amount=2_000_000
                ]
                .concat(),
            }
        }

        fn maker_ata_a_data(&self) -> Vec<u8> {
            // SPL Token account: mint(0..32), owner(32..64), amount(64..72),
            // delegate:COption(72..108), state(108)=1
            let mut d = vec![0u8; 165];
            d[0..32].copy_from_slice(self.mint_a.as_array());
            d[32..64].copy_from_slice(self.maker.as_array());
            d[64..72].copy_from_slice(&1_000_000u64.to_le_bytes());
            d[108] = 1; // initialized
            d
        }

        fn vault_ata_data(&self) -> Vec<u8> {
            let mut d = vec![0u8; 165];
            d[0..32].copy_from_slice(self.mint_a.as_array());
            d[108] = 1; // initialized
            d
        }

        fn accounts(&self) -> Vec<(Address, Account)> {
            self.accounts_with(
                self.maker_ata_a_data(),
                self.vault_ata_data(),
                vec![0u8; 154],
                true,
                self.program_id,
            )
        }

        fn accounts_with(
            &self,
            maker_ata_a_data: Vec<u8>,
            vault_ata_data: Vec<u8>,
            escrow_data: Vec<u8>,
            maker_is_signer: bool,
            escrow_owner: Address,
        ) -> Vec<(Address, Account)> {
            let _ = maker_is_signer; // signer flag is in AccountMeta, not Account
            vec![
                (self.maker, Account { lamports: 1_000_000_000, data: vec![], owner: self.system_prog, executable: false, ..Default::default() }),
                (self.maker_ata_a, Account { lamports: 2_039_280, data: maker_ata_a_data, owner: self.token_prog, executable: false, ..Default::default() }),
                (self.vault_ata, Account { lamports: 2_039_280, data: vault_ata_data, owner: self.token_prog, executable: false, ..Default::default() }),
                (self.escrow, Account { lamports: 1_141_440, data: escrow_data, owner: escrow_owner, executable: false, ..Default::default() }),
                (self.mint_a, Account { lamports: 1_461_600, data: vec![0u8; 82], owner: self.token_prog, executable: false, ..Default::default() }),
                (self.mint_b, Account { lamports: 1_461_600, data: vec![0u8; 82], owner: self.token_prog, executable: false, ..Default::default() }),
                (self.token_prog, Account { lamports: 1_141_440, data: vec![], owner: loader_keys::LOADER_V2, executable: true, ..Default::default() }),
            ]
        }

        fn instruction(&self, metas: Vec<AccountMeta>) -> Instruction {
            Instruction::new_with_bytes(self.program_id, &self.instruction_data, metas)
        }

        fn default_metas(&self) -> Vec<AccountMeta> {
            self.default_metas_with_signer(true)
        }

        fn default_metas_with_signer(&self, signer: bool) -> Vec<AccountMeta> {
            vec![
                AccountMeta::new(self.maker, signer),
                AccountMeta::new(self.maker_ata_a, false),
                AccountMeta::new(self.vault_ata, false),
                AccountMeta::new(self.escrow, false),
                AccountMeta::new_readonly(self.mint_a, false),
                AccountMeta::new_readonly(self.mint_b, false),
                AccountMeta::new_readonly(self.token_prog, false),
            ]
        }

        fn mollusk(&self) -> Mollusk {
            let mut m = Mollusk::new(&self.program_id, "deploy/assembly_token_transfer");
            let elf = std::fs::read("tests/fixtures/spl_token.so").unwrap();
            m.program_cache.add_program(&self.token_prog, &loader_keys::LOADER_V2, &elf);
            m
        }
    }

    #[test]
    fn test_make_offer_success() {
        let f = Fixture::new();
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &f.accounts(),
            &[Check::success()],
        );
    }

    #[test]
    fn test_make_offer_wrong_accounts_number() {
        let f = Fixture::new();
        // only 2 accounts
        let metas = vec![
            AccountMeta::new(f.maker, true),
            AccountMeta::new(f.maker_ata_a, false),
        ];
        let accounts = vec![
            (f.maker, Account { lamports: 1_000_000_000, data: vec![], owner: f.system_prog, executable: false, ..Default::default() }),
            (f.maker_ata_a, Account { lamports: 2_039_280, data: f.maker_ata_a_data(), owner: f.token_prog, executable: false, ..Default::default() }),
        ];
        f.mollusk().process_and_validate_instruction(
            &f.instruction(metas),
            &accounts,
            &[Check::err(ProgramError::Custom(0x02))],
        );
    }

    #[test]
    fn test_make_offer_no_signer() {
        let f = Fixture::new();
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas_with_signer(false)),
            &f.accounts(),
            &[Check::err(ProgramError::Custom(0x03))],
        );
    }

    #[test]
    fn test_make_offer_wrong_escrow_owner() {
        let f = Fixture::new();
        let accounts = f.accounts_with(
            f.maker_ata_a_data(),
            f.vault_ata_data(),
            vec![0u8; 154],
            true,
            f.system_prog, // wrong owner
        );
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &accounts,
            &[Check::err(ProgramError::Custom(0x04))],
        );
    }

    #[test]
    fn test_make_offer_escrow_not_fresh() {
        let f = Fixture::new();
        let mut escrow_data = vec![0u8; 154];
        escrow_data[0] = 1; // state = Complete, not Active
        let accounts = f.accounts_with(
            f.maker_ata_a_data(),
            f.vault_ata_data(),
            escrow_data,
            true,
            f.program_id,
        );
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &accounts,
            &[Check::err(ProgramError::Custom(0x05))],
        );
    }

    #[test]
    fn test_make_offer_wrong_escrow_size() {
        let f = Fixture::new();
        let accounts = f.accounts_with(
            f.maker_ata_a_data(),
            f.vault_ata_data(),
            vec![0u8; 100], // wrong size (expected 154)
            true,
            f.program_id,
        );
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &accounts,
            &[Check::err(ProgramError::Custom(0x07))],
        );
    }

    #[test]
    fn test_make_offer_zero_amount() {
        let f = Fixture::new();
        // a_amount = 0
        let ix_data: Vec<u8> = [
            vec![0u8, 254u8],
            0u64.to_le_bytes().to_vec(),
            0u64.to_le_bytes().to_vec(), // a_amount = 0
            2_000_000u64.to_le_bytes().to_vec(),
        ]
        .concat();
        let instruction = Instruction::new_with_bytes(f.program_id, &ix_data, f.default_metas());
        f.mollusk().process_and_validate_instruction(
            &instruction,
            &f.accounts(),
            &[Check::err(ProgramError::Custom(0x08))],
        );
    }

    #[test]
    fn test_make_offer_wrong_ata_owner() {
        let f = Fixture::new();
        // maker_ata_a.owner = some other key, not maker
        let other = address("11111111111111111111111111111112");
        let mut ata_data = f.maker_ata_a_data();
        ata_data[32..64].copy_from_slice(other.as_array()); // owner = other
        let accounts = f.accounts_with(
            ata_data,
            f.vault_ata_data(),
            vec![0u8; 154],
            true,
            f.program_id,
        );
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &accounts,
            &[Check::err(ProgramError::Custom(0x09))],
        );
    }

    struct TakeFixture {
        program_id: Address,
        taker: Address,
        taker_ata_b: Address,
        maker_ata_b: Address,
        vault_ata: Address,
        taker_ata_a: Address,
        escrow: Address,
        bump: u8,
        nonce: u64,
        mint_a: Address,
        mint_b: Address,
        token_prog: Address,
        system_prog: Address,
        maker: Address,
    }

    impl TakeFixture {
        fn new() -> Self {
            let program_id_bytes: [u8; 32] =
                std::fs::read("deploy/assembly_token_transfer-keypair.json").unwrap()[..32]
                    .try_into()
                    .unwrap();
            let program_id = Address::new_from_array(program_id_bytes);
            let maker = address("524HMdYYBy6TAn4dK5vCcjiTmT2sxV6Xoue5EXrz22Ca");
            let nonce = 0u64;
            let (escrow, bump) = Address::find_program_address(
                &[b"escrow", maker.as_array(), &nonce.to_le_bytes()],
                &program_id,
            );
            Self {
                program_id,
                maker,
                taker:       address("4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofM"),
                taker_ata_b: address("8opHzTAnfzRpPEx21XtnrVTX28YQuCpAjcn1PczScKh"),
                maker_ata_b: address("CiDwVBFgWV9E5MvXWoLgnEgn2hK7rJikbvfWavzAQz3"),
                vault_ata:   address("GJRs4FwHtemZ5ZE9x3FNvJ8TMwitKTh21yxdRPqn7v5"),
                taker_ata_a: address("GcdayuLaLyrdmUu324nahyv33G5poQdLUEZ1nEytDeP"),
                escrow,
                bump,
                nonce,
                mint_a:      address("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
                mint_b:      address("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"),
                token_prog:  address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"),
                system_prog: address("11111111111111111111111111111111"),
            }
        }

        fn token_account_data(&self, mint: &Address, owner: &Address, amount: u64) -> Vec<u8> {
            let mut d = vec![0u8; 165];
            d[0..32].copy_from_slice(mint.as_array());
            d[32..64].copy_from_slice(owner.as_array());
            d[64..72].copy_from_slice(&amount.to_le_bytes());
            d[108] = 1; // state = initialized
            d
        }

        fn escrow_data(&self) -> Vec<u8> {
            let mut d = vec![0u8; 154];
            d[0] = 0;            // state = Active
            d[1] = self.bump;
            d[2..10].copy_from_slice(&self.nonce.to_le_bytes());
            d[0x0A..0x2A].copy_from_slice(self.maker.as_array());
            d[0x2A..0x4A].copy_from_slice(self.mint_a.as_array());
            d[0x4A..0x6A].copy_from_slice(self.mint_b.as_array());
            d[0x6A..0x72].copy_from_slice(&1_000_000u64.to_le_bytes());
            d[0x72..0x7A].copy_from_slice(&2_000_000u64.to_le_bytes());
            d[0x7A..0x9A].copy_from_slice(self.vault_ata.as_array());
            d
        }

        fn accounts(&self) -> Vec<(Address, Account)> {
            vec![
                (self.taker,       Account { lamports: 1_000_000_000, data: vec![], owner: self.system_prog, executable: false, ..Default::default() }),
                (self.taker_ata_b, Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_b, &self.taker, 2_000_000), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.maker_ata_b, Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_b, &self.maker, 0), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.vault_ata,   Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_a, &self.escrow, 1_000_000), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.taker_ata_a, Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_a, &self.taker, 0), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.escrow,      Account { lamports: 1_141_440, data: self.escrow_data(), owner: self.program_id, executable: false, ..Default::default() }),
                (self.mint_a,      Account { lamports: 1_461_600, data: vec![0u8; 82], owner: self.token_prog, executable: false, ..Default::default() }),
                (self.mint_b,      Account { lamports: 1_461_600, data: vec![0u8; 82], owner: self.token_prog, executable: false, ..Default::default() }),
                (self.token_prog,  Account { lamports: 1_141_440, data: vec![], owner: loader_keys::LOADER_V2, executable: true, ..Default::default() }),
            ]
        }

        fn instruction(&self) -> Instruction {
            let metas = vec![
                AccountMeta::new(self.taker,       true),  // acct0: taker (signer)
                AccountMeta::new(self.taker_ata_b, false), // acct1: taker_ata_b
                AccountMeta::new(self.maker_ata_b, false), // acct2: maker_ata_b
                AccountMeta::new(self.vault_ata,   false), // acct3: vault_ata
                AccountMeta::new(self.taker_ata_a, false), // acct4: taker_ata_a
                AccountMeta::new(self.escrow,      false), // acct5: escrow
                AccountMeta::new_readonly(self.mint_a,     false), // acct6
                AccountMeta::new_readonly(self.mint_b,     false), // acct7
                AccountMeta::new_readonly(self.token_prog, false), // acct8
            ];
            Instruction::new_with_bytes(self.program_id, &[1u8], metas)
        }

        fn accounts_modified<F: FnOnce(&mut Vec<(Address, Account)>)>(&self, f: F) -> Vec<(Address, Account)> {
            let mut accts = self.accounts();
            f(&mut accts);
            accts
        }

        fn mollusk(&self) -> Mollusk {
            let mut m = Mollusk::new(&self.program_id, "deploy/assembly_token_transfer");
            let elf = std::fs::read("tests/fixtures/spl_token.so").unwrap();
            m.program_cache.add_program(&self.token_prog, &loader_keys::LOADER_V2, &elf);
            m
        }
    }

    #[test]
    fn test_take_offer_success() {
        let f = TakeFixture::new();
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &f.accounts(),
            &[Check::success()],
        );
    }

    #[test]
    fn test_take_wrong_accounts_number() {
        let f = TakeFixture::new();
        let metas = vec![
            AccountMeta::new(f.taker, true),
            AccountMeta::new(f.taker_ata_b, false),
        ];
        let accounts = vec![
            (f.taker, Account { lamports: 1_000_000_000, data: vec![], owner: f.system_prog, executable: false, ..Default::default() }),
            (f.taker_ata_b, Account { lamports: 2_039_280, data: f.token_account_data(&f.mint_b, &f.taker, 2_000_000), owner: f.token_prog, executable: false, ..Default::default() }),
        ];
        f.mollusk().process_and_validate_instruction(
            &Instruction::new_with_bytes(f.program_id, &[1u8], metas),
            &accounts,
            &[Check::err(ProgramError::Custom(0x02))],
        );
    }

    #[test]
    fn test_take_no_signer() {
        let f = TakeFixture::new();
        let metas = vec![
            AccountMeta::new(f.taker,       false), // not signer
            AccountMeta::new(f.taker_ata_b, false),
            AccountMeta::new(f.maker_ata_b, false),
            AccountMeta::new(f.vault_ata,   false),
            AccountMeta::new(f.taker_ata_a, false),
            AccountMeta::new(f.escrow,      false),
            AccountMeta::new_readonly(f.mint_a,     false),
            AccountMeta::new_readonly(f.mint_b,     false),
            AccountMeta::new_readonly(f.token_prog, false),
        ];
        f.mollusk().process_and_validate_instruction(
            &Instruction::new_with_bytes(f.program_id, &[1u8], metas),
            &f.accounts(),
            &[Check::err(ProgramError::Custom(0x03))],
        );
    }

    #[test]
    fn test_take_wrong_escrow_owner() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[5].1.owner = f.system_prog; // escrow owned by system, not program
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x04))],
        );
    }

    #[test]
    fn test_take_escrow_not_active() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[5].1.data[0] = 1; // state = Completed
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x05))],
        );
    }

    #[test]
    fn test_take_wrong_escrow_size() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[5].1.data = vec![0u8; 100]; // wrong size
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x07))],
        );
    }

    #[test]
    fn test_take_taker_atab_wrong_mint() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // taker_ata_b.mint = mint_a instead of mint_b
            a[1].1.data[0..32].copy_from_slice(f.mint_a.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0A))],
        );
    }

    #[test]
    fn test_take_taker_atab_wrong_owner() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // taker_ata_b.owner = maker instead of taker
            a[1].1.data[32..64].copy_from_slice(f.maker.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0B))],
        );
    }

    #[test]
    fn test_take_wrong_vault_ata() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // escrow.vault_ata points to a different address
            a[5].1.data[0x7A..0x9A].copy_from_slice(f.taker_ata_a.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0C))],
        );
    }

    #[test]
    fn test_take_maker_atab_wrong_owner() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // maker_ata_b.owner = taker instead of maker
            a[2].1.data[32..64].copy_from_slice(f.taker.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0D))],
        );
    }

    #[test]
    fn test_take_maker_atab_wrong_mint() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // maker_ata_b.mint = mint_a instead of mint_b
            a[2].1.data[0..32].copy_from_slice(f.mint_a.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0A))],
        );
    }

    #[test]
    fn test_take_taker_ataa_wrong_mint() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // taker_ata_a.mint = mint_b instead of mint_a
            a[4].1.data[0..32].copy_from_slice(f.mint_b.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0A))],
        );
    }

    #[test]
    fn test_take_taker_ataa_wrong_owner() {
        let f = TakeFixture::new();
        let accounts = f.accounts_modified(|a| {
            // taker_ata_a.owner = maker instead of taker
            a[4].1.data[32..64].copy_from_slice(f.maker.as_array());
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0B))],
        );
    }

    #[test]
    fn test_make_offer_mint_mismatch() {
        let f = Fixture::new();
        // maker_ata_a.mint = some other mint, not mint_a
        let wrong_mint = address("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"); // mint_b
        let mut ata_data = f.maker_ata_a_data();
        ata_data[0..32].copy_from_slice(wrong_mint.as_array());
        let accounts = f.accounts_with(
            ata_data,
            f.vault_ata_data(),
            vec![0u8; 154],
            true,
            f.program_id,
        );
        f.mollusk().process_and_validate_instruction(
            &f.instruction(f.default_metas()),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0A))],
        );
    }

    struct CancelFixture {
        program_id: Address,
        maker: Address,
        maker_ata_a: Address,
        vault_ata: Address,
        escrow: Address,
        bump: u8,
        nonce: u64,
        mint_a: Address,
        mint_b: Address,
        token_prog: Address,
        system_prog: Address,
    }

    impl CancelFixture {
        fn new() -> Self {
            let program_id_bytes: [u8; 32] =
                std::fs::read("deploy/assembly_token_transfer-keypair.json").unwrap()[..32]
                    .try_into()
                    .unwrap();
            let program_id = Address::new_from_array(program_id_bytes);
            let maker = address("524HMdYYBy6TAn4dK5vCcjiTmT2sxV6Xoue5EXrz22Ca");
            let nonce = 0u64;
            let (escrow, bump) = Address::find_program_address(
                &[b"escrow", maker.as_array(), &nonce.to_le_bytes()],
                &program_id,
            );
            Self {
                program_id,
                maker,
                maker_ata_a: address("7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2"),
                vault_ata:   address("GJRs4FwHtemZ5ZE9x3FNvJ8TMwitKTh21yxdRPqn7v5"),
                escrow,
                bump,
                nonce,
                mint_a:     address("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"),
                mint_b:     address("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"),
                token_prog: address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"),
                system_prog: address("11111111111111111111111111111111"),
            }
        }

        fn token_account_data(&self, mint: &Address, owner: &Address, amount: u64) -> Vec<u8> {
            let mut d = vec![0u8; 165];
            d[0..32].copy_from_slice(mint.as_array());
            d[32..64].copy_from_slice(owner.as_array());
            d[64..72].copy_from_slice(&amount.to_le_bytes());
            d[108] = 1; // initialized
            d
        }

        fn escrow_data(&self) -> Vec<u8> {
            let mut d = vec![0u8; 154];
            d[0] = 0; // state = Active
            d[1] = self.bump;
            d[2..10].copy_from_slice(&self.nonce.to_le_bytes());
            d[0x0A..0x2A].copy_from_slice(self.maker.as_array());
            d[0x2A..0x4A].copy_from_slice(self.mint_a.as_array());
            d[0x4A..0x6A].copy_from_slice(self.mint_b.as_array());
            d[0x6A..0x72].copy_from_slice(&1_000_000u64.to_le_bytes());
            d[0x72..0x7A].copy_from_slice(&2_000_000u64.to_le_bytes());
            d[0x7A..0x9A].copy_from_slice(self.vault_ata.as_array());
            d
        }

        fn accounts(&self) -> Vec<(Address, Account)> {
            vec![
                (self.maker,      Account { lamports: 1_000_000_000, data: vec![], owner: self.system_prog, executable: false, ..Default::default() }),
                (self.maker_ata_a, Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_a, &self.maker, 0), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.vault_ata,  Account { lamports: 2_039_280, data: self.token_account_data(&self.mint_a, &self.escrow, 1_000_000), owner: self.token_prog, executable: false, ..Default::default() }),
                (self.escrow,     Account { lamports: 1_141_440, data: self.escrow_data(), owner: self.program_id, executable: false, ..Default::default() }),
                (self.token_prog, Account { lamports: 1_141_440, data: vec![], owner: loader_keys::LOADER_V2, executable: true, ..Default::default() }),
            ]
        }

        fn instruction(&self) -> Instruction {
            let metas = vec![
                AccountMeta::new(self.maker,      true),  // acct0: maker (signer)
                AccountMeta::new(self.maker_ata_a, false), // acct1: maker_ata_a
                AccountMeta::new(self.vault_ata,  false), // acct2: vault_ata
                AccountMeta::new(self.escrow,     false), // acct3: escrow
                AccountMeta::new_readonly(self.token_prog, false), // acct4
            ];
            Instruction::new_with_bytes(self.program_id, &[2u8], metas)
        }

        fn accounts_modified<F: FnOnce(&mut Vec<(Address, Account)>)>(&self, f: F) -> Vec<(Address, Account)> {
            let mut accts = self.accounts();
            f(&mut accts);
            accts
        }

        fn mollusk(&self) -> Mollusk {
            let mut m = Mollusk::new(&self.program_id, "deploy/assembly_token_transfer");
            let elf = std::fs::read("tests/fixtures/spl_token.so").unwrap();
            m.program_cache.add_program(&self.token_prog, &loader_keys::LOADER_V2, &elf);
            m
        }
    }

    #[test]
    fn test_cancel_offer_success() {
        let f = CancelFixture::new();
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &f.accounts(),
            &[Check::success()],
        );
    }

    #[test]
    fn test_cancel_wrong_accounts_number() {
        let f = CancelFixture::new();
        let metas = vec![
            AccountMeta::new(f.maker, true),
            AccountMeta::new(f.maker_ata_a, false),
        ];
        let accounts = vec![
            (f.maker,      Account { lamports: 1_000_000_000, data: vec![], owner: f.system_prog, executable: false, ..Default::default() }),
            (f.maker_ata_a, Account { lamports: 2_039_280, data: f.token_account_data(&f.mint_a, &f.maker, 0), owner: f.token_prog, executable: false, ..Default::default() }),
        ];
        f.mollusk().process_and_validate_instruction(
            &Instruction::new_with_bytes(f.program_id, &[2u8], metas),
            &accounts,
            &[Check::err(ProgramError::Custom(0x02))],
        );
    }

    #[test]
    fn test_cancel_no_signer() {
        let f = CancelFixture::new();
        let metas = vec![
            AccountMeta::new(f.maker,       false), // not signer
            AccountMeta::new(f.maker_ata_a, false),
            AccountMeta::new(f.vault_ata,   false),
            AccountMeta::new(f.escrow,      false),
            AccountMeta::new_readonly(f.token_prog, false),
        ];
        f.mollusk().process_and_validate_instruction(
            &Instruction::new_with_bytes(f.program_id, &[2u8], metas),
            &f.accounts(),
            &[Check::err(ProgramError::Custom(0x03))],
        );
    }

    #[test]
    fn test_cancel_wrong_escrow_owner() {
        let f = CancelFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[3].1.owner = f.system_prog; // escrow owned by system, not program
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x04))],
        );
    }

    #[test]
    fn test_cancel_wrong_escrow_size() {
        let f = CancelFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[3].1.data = vec![0u8; 100]; // wrong size
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x07))],
        );
    }

    #[test]
    fn test_cancel_escrow_not_active() {
        let f = CancelFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[3].1.data[0] = 1; // state = Completed
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x05))],
        );
    }

    #[test]
    fn test_cancel_maker_mismatch() {
        let f = CancelFixture::new();
        let other = address("4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofM");
        let accounts = f.accounts_modified(|a| {
            a[3].1.data[0x0A..0x2A].copy_from_slice(other.as_array()); // escrow.maker = other
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0E))],
        );
    }

    #[test]
    fn test_cancel_wrong_vault_ata() {
        let f = CancelFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[3].1.data[0x7A..0x9A].copy_from_slice(f.maker_ata_a.as_array()); // escrow.vault_ata = wrong key
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0C))],
        );
    }

    #[test]
    fn test_cancel_maker_ata_wrong_mint() {
        let f = CancelFixture::new();
        let accounts = f.accounts_modified(|a| {
            a[1].1.data[0..32].copy_from_slice(f.mint_b.as_array()); // maker_ata_a.mint = mint_b
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x0A))],
        );
    }

    #[test]
    fn test_cancel_maker_ata_wrong_owner() {
        let f = CancelFixture::new();
        let other = address("4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofM");
        let accounts = f.accounts_modified(|a| {
            a[1].1.data[32..64].copy_from_slice(other.as_array()); // maker_ata_a.owner = other
        });
        f.mollusk().process_and_validate_instruction(
            &f.instruction(),
            &accounts,
            &[Check::err(ProgramError::Custom(0x09))],
        );
    }
}
