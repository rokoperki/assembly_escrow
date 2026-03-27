#[cfg(test)]
mod tests {
    use mollusk_svm::{program::loader_keys, result::Check, Mollusk};
    use solana_account::Account;
    use solana_address::Address;
    use solana_instruction::{AccountMeta, Instruction};

    fn address(base58: &str) -> Address {
        let bytes = bs58::decode(base58).into_vec().expect("valid base58");
        Address::new_from_array(bytes.try_into().expect("32 bytes"))
    }

    #[test]
    fn test_make_offer_success() {
        let program_id_bytes: [u8; 32] = std::fs::read("deploy/assembly_token_transfer-keypair.json")
            .unwrap()[..32]
            .try_into()
            .unwrap();
        let program_id = Address::new_from_array(program_id_bytes);

        let maker        = address("524HMdYYBy6TAn4dK5vCcjiTmT2sxV6Xoue5EXrz22Ca");
        let maker_ata_a  = address("7Np41oeYqPefeNQEHSv1UDhYrehxin3NStELsSKCT4K2");
        let vault_ata    = address("GJRs4FwHtemZ5ZE9x3FNvJ8TMwitKTh21yxdRPqn7v5");
        let escrow       = address("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");
        let mint_a       = address("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
        let mint_b       = address("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB");
        let token_prog   = address("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
        let system_prog  = address("11111111111111111111111111111111");

        // SPL Token mint: 32-byte mint_a pubkey
        let mint_a_bytes = *mint_a.as_array();

        // SPL Token Account layout (165 bytes):
        //   mint(0..32), owner(32..64), amount(64..72),
        //   delegate:COption<Pubkey>(72..108), state(108)=1, ...
        // maker_ata_a data: mint(32) || owner=maker(32) || amount=1_000_000(8) || delegate=None(36) || state=1
        let mut maker_ata_a_data = vec![0u8; 165];
        maker_ata_a_data[0..32].copy_from_slice(&mint_a_bytes);
        maker_ata_a_data[32..64].copy_from_slice(maker.as_array());
        maker_ata_a_data[64..72].copy_from_slice(&1_000_000u64.to_le_bytes());
        maker_ata_a_data[108] = 1; // initialized

        // vault_ata data: mint(32) || zeros(76) || state=1
        let mut vault_ata_data = vec![0u8; 165];
        vault_ata_data[0..32].copy_from_slice(&mint_a_bytes);
        vault_ata_data[108] = 1; // initialized

        // escrow data: 154 zero bytes (fresh state)
        let escrow_data = vec![0u8; 154];

        // mint data: 82 zero bytes (we only check owner/key, not mint fields)
        let mint_data = vec![0u8; 82];

        let accounts = vec![
            (
                maker,
                Account {
                    lamports: 1_000_000_000,
                    data: vec![],
                    owner: system_prog,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                maker_ata_a,
                Account {
                    lamports: 2_039_280,
                    data: maker_ata_a_data,
                    owner: token_prog,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                vault_ata,
                Account {
                    lamports: 2_039_280,
                    data: vault_ata_data,
                    owner: token_prog,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                escrow,
                Account {
                    lamports: 1_141_440,
                    data: escrow_data,
                    owner: program_id,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                mint_a,
                Account {
                    lamports: 1_461_600,
                    data: mint_data.clone(),
                    owner: token_prog,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                mint_b,
                Account {
                    lamports: 1_461_600,
                    data: mint_data,
                    owner: token_prog,
                    executable: false,
                    ..Default::default()
                },
            ),
            (
                token_prog,
                Account {
                    lamports: 1_141_440,
                    data: vec![],
                    owner: loader_keys::LOADER_V2,
                    executable: true,
                    ..Default::default()
                },
            ),
        ];

        // instruction_data: [disc=0, bump=254, nonce(8)=0, a_amount(8)=1_000_000, b_amount(8)=2_000_000]
        let instruction_data: Vec<u8> = [
            vec![0u8, 254u8],                    // disc, bump
            0u64.to_le_bytes().to_vec(),          // nonce
            1_000_000u64.to_le_bytes().to_vec(),  // a_amount
            2_000_000u64.to_le_bytes().to_vec(),  // b_amount
        ]
        .concat();

        let instruction = Instruction::new_with_bytes(
            program_id,
            &instruction_data,
            vec![
                AccountMeta::new(maker, true),
                AccountMeta::new(maker_ata_a, false),
                AccountMeta::new(vault_ata, false),
                AccountMeta::new(escrow, false),
                AccountMeta::new_readonly(mint_a, false),
                AccountMeta::new_readonly(mint_b, false),
                AccountMeta::new_readonly(token_prog, false),
            ],
        );

        let mut mollusk = Mollusk::new(&program_id, "deploy/assembly_token_transfer");

        let spl_token_elf = std::fs::read("tests/fixtures/spl_token.so").unwrap();
        mollusk.program_cache.add_program(&token_prog, &loader_keys::LOADER_V2, &spl_token_elf);

        mollusk.process_and_validate_instruction(&instruction, &accounts, &[Check::success()]);
    }
}
