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
}
