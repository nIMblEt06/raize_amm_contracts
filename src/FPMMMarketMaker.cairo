use starknet::{ContractAddress, ClassHash};

#[derive(Drop, Serde, starknet::Store, Copy)]
pub struct Outcome {
    name: felt252,
    num_shares_in_pool: u128,
    winner: bool,
}

#[derive(Drop, Serde, starknet::Store)]
pub struct FPMMMarket {
    num_outcomes: u32,
    deadline: u128,
    is_active: bool,
    is_settled: bool
}

#[starknet::interface]
pub trait IMarketMaker<TContractState> {
    fn get_collateral_token(self: @TContractState) -> ContractAddress; //

    fn get_fee(self: @TContractState) -> u32; //

    fn set_fee(ref self: TContractState, fee: u32); //

    fn current_liquidity(self: @TContractState) -> u128; //

    fn fees_withdrawable_by(self: @TContractState, account: ContractAddress) -> u256; //

    fn get_user_balance(self: @TContractState, account: ContractAddress) -> u256; //

    fn get_user_market_share(
        self: @TContractState, account: ContractAddress, market_id: u256, outcome_index: u32
    ) -> u256; //

    fn get_market(self: @TContractState, market_id: u256) -> FPMMMarket;

    fn disable_market(ref self: TContractState, market_id: u256);

    fn set_winner(ref self: TContractState, market_id: u256, outcome_index: u32);

    fn get_outcome(self: @TContractState, market_id: u256, outcome_index: u32) -> Outcome;

    fn init_market(ref self: TContractState, outcomes: Array<felt252>, deadline: u128);

    fn get_num_markets(self: @TContractState) -> u256;

    fn add_funding(ref self: TContractState, added_funds: u128);

    fn remove_funding(ref self: TContractState, funds_to_remove: u128);

    fn calc_buy_amount(
        self: @TContractState, market_id: u256, investment_amount: u128, outcome_index: u32
    ) -> u128;

    fn calc_sell_amount(
        self: @TContractState, market_id: u256, return_amount: u128, outcome_index: u32
    ) -> u128;

    fn buy(
        ref self: TContractState,
        market_id: u256,
        investment_amount: u128,
        outcome_index: u32,
        min_outcome_tokens_to_buy: u128
    );

    fn sell(
        ref self: TContractState,
        market_id: u256,
        return_amount: u128,
        outcome_index: u32,
        max_outcome_tokens_to_sell: u128
    );

    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}

#[starknet::contract]
pub mod FixedProductMarketMaker {
    use core::starknet::event::EventEmitter;
    use starknet::ContractAddress;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::{get_caller_address, get_contract_address, ClassHash};
    use starknet::SyscallResultTrait;
    use super::Outcome;
    use super::FPMMMarket;


    #[storage]
    struct Storage {
        num_markets: u256, // number of markets created
        markets: LegacyMap<u256, FPMMMarket>, // LegacyMap market_num to markets
        collateral_token: ContractAddress, // token used as collateral
        fee: u32, // fee charged on trades
        liquidity_pool: u128, // total unified liquidity in the pool, will be used to create outcome tokens for each market
        liquidity_balance: LegacyMap<
            ContractAddress, u256
        >, // liquidity added in pool by each account
        fees_accrued: u256, // total fees accrued
        balances: LegacyMap<(u256, ContractAddress, u32), u256>,
        outcomes: LegacyMap<(u256, u32), Outcome>,
        owner: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        FPMMMarketInit: FPMMMarketInit,
        FPMMFundingAdded: FPMMFundingAdded,
        FPMMFundingRemoved: FPMMFundingRemoved,
        FPMMBuy: FPMMBuy,
        FPMMSell: FPMMSell,
        Upgraded: Upgraded
    }

    #[derive(Drop, starknet::Event)]
    struct FPMMFundingAdded {
        funder: ContractAddress,
        amounts_added: u256
    }

    #[derive(Drop, starknet::Event)]
    struct FPMMFundingRemoved {
        funder: ContractAddress,
        collateral_removed_from_fee_pool: u256,
        amounts_removed: u256
    }

    #[derive(Drop, starknet::Event)]
    struct FPMMBuy {
        buyer: ContractAddress,
        investment_amount: u128,
        outcome_index: u32,
        outcome_tokens_bought: u256
    }

    #[derive(Drop, starknet::Event)]
    struct FPMMSell {
        seller: ContractAddress,
        return_amount: u128,
        outcome_index: u32,
        outcome_tokens_sold: u256
    }

    #[derive(Drop, starknet::Event)]
    struct FPMMMarketInit {
        market_id: u256,
        outcomes: Array<felt252>,
        deadline: u128
    }

    #[derive(Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        _collateral_token: ContractAddress,
        _fee: u32,
        _owner: ContractAddress
    ) {
        self.collateral_token.write(_collateral_token);
        self.fee.write(_fee);
        self.owner.write(_owner);
    }

    #[abi(embed_v0)]
    impl MarketFactory of super::IMarketMaker<ContractState> {
        fn get_collateral_token(self: @ContractState) -> ContractAddress {
            self.collateral_token.read()
        }

        fn get_fee(self: @ContractState) -> u32 {
            self.fee.read()
        }

        fn set_fee(ref self: ContractState, fee: u32) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can set fee');
            self.fee.write(fee);
        }

        fn current_liquidity(self: @ContractState) -> u128 {
            self.liquidity_pool.read()
        }

        fn get_num_markets(self: @ContractState) -> u256 {
            self.num_markets.read()
        }

        fn fees_withdrawable_by(self: @ContractState, account: ContractAddress) -> u256 {
            let amount = self.fees_accrued.read()
                * self.liquidity_balance.read(account)
                / self.liquidity_pool.read().into();
            amount + self.liquidity_balance.read(account)
        }

        fn disable_market(ref self: ContractState, market_id: u256) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can disable market');
            let market = self.markets.read(market_id);
            assert(market.is_active, 'Market is already disabled');
            self
                .markets
                .write(
                    market_id,
                    FPMMMarket {
                        num_outcomes: market.num_outcomes,
                        deadline: market.deadline,
                        is_active: false,
                        is_settled: market.is_settled
                    }
                );
        }

        fn set_winner(ref self: ContractState, market_id: u256, outcome_index: u32) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can set winner');
            let market = self.markets.read(market_id);
            assert(market.is_active, 'Market is not active');
            assert(!market.is_settled, 'Market is already settled');
            let mut i = 0;
            loop {
                if i == market.num_outcomes {
                    break;
                }
                let mut outcome = self.outcomes.read((market_id, i));
                if i == outcome_index {
                    self
                        .outcomes
                        .write(
                            (market_id, i),
                            Outcome {
                                name: outcome.name,
                                num_shares_in_pool: outcome.num_shares_in_pool,
                                winner: true
                            }
                        );
                }
                i += 1;
            };
            self
                .markets
                .write(
                    market_id,
                    FPMMMarket {
                        num_outcomes: market.num_outcomes,
                        deadline: market.deadline,
                        is_active: false,
                        is_settled: true
                    }
                );
        }


        fn add_funding(ref self: ContractState, added_funds: u128) {
            assert(added_funds > 0, 'Added funds must be positive');
            assert(
                IERC20Dispatcher { contract_address: self.collateral_token.read() }
                    .transfer_from(
                        get_caller_address(), get_contract_address(), added_funds.into()
                    ),
                'transfer failed'
            );
            self
                .liquidity_balance
                .write(
                    get_caller_address(),
                    self.liquidity_balance.read(get_caller_address()) + added_funds.into()
                );

            self.liquidity_pool.write(self.liquidity_pool.read() + added_funds);
            self
                .emit(
                    FPMMFundingAdded {
                        funder: get_caller_address(), amounts_added: added_funds.into()
                    }
                );
        }

        fn remove_funding(ref self: ContractState, funds_to_remove: u128) {
            assert(funds_to_remove > 0, 'Funds must be positive');
            assert(funds_to_remove <= self.liquidity_pool.read(), 'Cannot remove more than pool');
            assert(
                self.liquidity_balance.read(get_caller_address()) >= funds_to_remove.into(),
                'insufficient funds'
            );
            let amount = self.fees_accrued.read()
                * funds_to_remove.into()
                / self.liquidity_pool.read().into();
            let withdrawable_amount = self.fees_withdrawable_by(get_caller_address());
            assert(withdrawable_amount > 0, 'require non-zero balances');

            assert(
                IERC20Dispatcher { contract_address: self.collateral_token.read() }
                    .transfer(get_caller_address(), withdrawable_amount),
                'transfer failed'
            );
            self.fees_accrued.write(self.fees_accrued.read() - amount);
            self
                .liquidity_balance
                .write(
                    get_caller_address(),
                    self.liquidity_balance.read(get_caller_address()) - funds_to_remove.into()
                );

            self.liquidity_pool.write(self.liquidity_pool.read() - funds_to_remove);
            self
                .emit(
                    FPMMFundingRemoved {
                        funder: get_caller_address(),
                        amounts_removed: funds_to_remove.into(),
                        collateral_removed_from_fee_pool: amount
                    }
                );
        }

        fn calc_buy_amount(
            self: @ContractState, market_id: u256, investment_amount: u128, outcome_index: u32
        ) -> u128 {
            assert(investment_amount > 0, 'Investment must be positive');
            assert(market_id <= self.num_markets.read(), 'Invalid market ID');
            let market = self.markets.read(market_id);
            assert(outcome_index < market.num_outcomes, 'Invalid outcome index');
            let market = self.markets.read(market_id);
            assert(market.is_active, 'Market is not active');
            assert(!market.is_settled, 'Market is already settled');
            let pool_balances = self.get_pool_balances(market_id);
            let balance_copy = pool_balances.clone();
            let investment_amount_minus_fees = investment_amount
                - (investment_amount * self.fee.read().into() / 100);

            let mut new_outcome_balance: u128 = *pool_balances.at(outcome_index);

            let mut i: u32 = 0;
            while i != pool_balances.len()
                - 1 {
                    if i != outcome_index {
                        new_outcome_balance = new_outcome_balance
                            * *pool_balances.at(i)
                            / (*pool_balances.at(i) + investment_amount_minus_fees);
                    }
                    i += 1;
                };
            assert(new_outcome_balance > 0, 'must have non-zero balances');
            let min_outcome_tokens_to_buy = *balance_copy.at(outcome_index)
                + investment_amount_minus_fees
                - new_outcome_balance;
            min_outcome_tokens_to_buy
        }

        fn calc_sell_amount(
            self: @ContractState, market_id: u256, return_amount: u128, outcome_index: u32
        ) -> u128 {
            assert(return_amount > 0, 'must be positive');
            assert(market_id <= self.num_markets.read(), 'Invalid market ID');
            let market = self.markets.read(market_id);
            assert(outcome_index < market.num_outcomes, 'Invalid outcome index');
            assert(market.is_active, 'Market is not active');
            assert(!market.is_settled, 'Market is already settled');
            let pool_balances = self.get_pool_balances(market_id);
            let balance_copy = pool_balances.clone();
            let return__amount_minus_fees = return_amount
                - (return_amount * self.fee.read().into() / 100);

            let mut new_outcome_balance: u128 = *pool_balances.at(outcome_index);

            let mut i: u32 = 0;
            while i != pool_balances
                .len() {
                    if i != outcome_index {
                        new_outcome_balance = new_outcome_balance
                            * *pool_balances.at(i)
                            / (*pool_balances.at(i) - return__amount_minus_fees);
                    }
                    i += 1;
                };

            assert(new_outcome_balance > 0, 'must have non-zero balances');

            return__amount_minus_fees + new_outcome_balance - *balance_copy.at(outcome_index)
        }

        fn buy(
            ref self: ContractState,
            market_id: u256,
            investment_amount: u128,
            outcome_index: u32,
            min_outcome_tokens_to_buy: u128
        ) {
            let outcome_tokens_to_buy = self
                .calc_buy_amount(market_id, investment_amount, outcome_index);
            assert(
                outcome_tokens_to_buy >= min_outcome_tokens_to_buy, 'Receiving less than expected'
            );

            assert(
                IERC20Dispatcher { contract_address: self.collateral_token.read() }
                    .transfer_from(
                        get_caller_address(), get_contract_address(), investment_amount.into()
                    ),
                'transfer failed'
            );

            self
                .fees_accrued
                .write(
                    self.fees_accrued.read()
                        + (investment_amount.into() * self.fee.read().into() / 100)
                );

            let investment_amount_minus_fees = investment_amount
                - (investment_amount * self.fee.read().into() / 100);

            self
                .calc_new_pool_balances(
                    market_id,
                    investment_amount_minus_fees,
                    outcome_index,
                    outcome_tokens_to_buy,
                    true
                );

            self
                .balances
                .write(
                    (market_id, get_caller_address(), outcome_index),
                    self.balances.read((market_id, get_caller_address(), outcome_index))
                        + outcome_tokens_to_buy.into()
                );
            self
                .emit(
                    FPMMBuy {
                        buyer: get_caller_address(),
                        investment_amount,
                        outcome_index,
                        outcome_tokens_bought: outcome_tokens_to_buy.into()
                    }
                );
        }

        fn sell(
            ref self: ContractState,
            market_id: u256,
            return_amount: u128,
            outcome_index: u32,
            max_outcome_tokens_to_sell: u128
        ) {
            let outcome_tokens_to_sell = self
                .calc_sell_amount(market_id, return_amount, outcome_index);
            assert(
                outcome_tokens_to_sell <= max_outcome_tokens_to_sell, 'Selling more than expected'
            );
            assert(
                outcome_tokens_to_sell
                    .into() < self
                    .balances
                    .read((market_id, get_caller_address(), outcome_index)),
                'insufficient balance'
            );

            self
                .balances
                .write(
                    (market_id, get_caller_address(), outcome_index),
                    self.balances.read((market_id, get_caller_address(), outcome_index))
                        - outcome_tokens_to_sell.into()
                );

            self
                .fees_accrued
                .write(
                    self.fees_accrued.read() + (return_amount.into() * self.fee.read().into() / 100)
                );

            let return_amount_minus_fees = return_amount
                - (return_amount * self.fee.read().into() / 100);

            self
                .calc_new_pool_balances(
                    market_id,
                    return_amount_minus_fees,
                    outcome_index,
                    outcome_tokens_to_sell,
                    false
                );

            assert(
                IERC20Dispatcher { contract_address: self.collateral_token.read() }
                    .transfer(get_caller_address(), return_amount.into()),
                'transfer failed'
            );
            self
                .emit(
                    FPMMSell {
                        seller: get_caller_address(),
                        return_amount,
                        outcome_index,
                        outcome_tokens_sold: outcome_tokens_to_sell.into()
                    }
                );
        }

        fn get_user_balance(self: @ContractState, account: ContractAddress) -> u256 {
            self.liquidity_balance.read(account)
        }

        fn get_user_market_share(
            self: @ContractState, account: ContractAddress, market_id: u256, outcome_index: u32
        ) -> u256 {
            self.balances.read((market_id, account, outcome_index))
        }

        fn init_market(ref self: ContractState, outcomes: Array<felt252>, deadline: u128) {
            assert(!outcomes.is_empty(), 'Outcomes array cannot be empty');
            assert(outcomes.len() <= 256, 'Too many outcomes');
            assert(
                deadline > starknet::get_block_timestamp().into(), 'Deadline must be in the future'
            );
            let current_funding = self.liquidity_pool.read();
            assert(current_funding > 0, 'No liquidity in the pool');

            let market_id = self.num_markets.read() + 1;
            self.num_markets.write(market_id);
            let outcomes_copy = outcomes.clone();

            let num_outcomes = outcomes.len();
            let market = FPMMMarket { num_outcomes, deadline, is_active: true, is_settled: false };
            self.markets.write(market_id, market);

            let outcome_tokens = current_funding / 10 / num_outcomes.into();

            let mut i = 0;
            loop {
                if i == num_outcomes {
                    break;
                }
                self
                    .outcomes
                    .write(
                        (market_id, i),
                        Outcome {
                            name: *outcomes.at(i), num_shares_in_pool: outcome_tokens, winner: false
                        }
                    );
                i += 1;
            };

            self.emit(FPMMMarketInit { market_id: market_id, outcomes: outcomes_copy, deadline });
        }

        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert(get_caller_address() == self.owner.read(), 'Only owner can upgrade.');
            starknet::syscalls::replace_class_syscall(new_class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash: new_class_hash });
        }

        fn get_market(self: @ContractState, market_id: u256) -> FPMMMarket {
            self.markets.read(market_id)
        }

        fn get_outcome(self: @ContractState, market_id: u256, outcome_index: u32) -> Outcome {
            self.outcomes.read((market_id, outcome_index))
        }
    }


    #[generate_trait]
    impl FPMMInternal of FPMMInternalTrait {
        fn get_pool_balances(self: @ContractState, market_id: u256) -> Array<u128> {
            let market = self.markets.read(market_id);
            let num_outcomes = market.num_outcomes;
            let mut balances: Array<u128> = ArrayTrait::new();
            let mut i = 0;
            loop {
                if i == num_outcomes {
                    break;
                }
                balances.append(self.outcomes.read((market_id, i)).num_shares_in_pool);
                i += 1;
            };
            balances
        }

        fn calc_new_pool_balances(
            ref self: ContractState,
            market_id: u256,
            amount: u128,
            outcome_index: u32,
            shares_updated: u128,
            is_buy: bool
        ) {
            let market = self.markets.read(market_id);
            let num_outcomes = market.num_outcomes;
            let mut i = 0;
            loop {
                if i == num_outcomes {
                    break;
                }
                let mut outcome = self.outcomes.read((market_id, i));
                let shares_in_pool = outcome.num_shares_in_pool;
                if is_buy {
                    if i == outcome_index {
                        self
                            .outcomes
                            .write(
                                (market_id, i),
                                Outcome {
                                    name: outcome.name,
                                    num_shares_in_pool: shares_in_pool + amount - shares_updated,
                                    winner: false
                                }
                            );
                    } else {
                        self
                            .outcomes
                            .write(
                                (market_id, i),
                                Outcome {
                                    name: outcome.name,
                                    num_shares_in_pool: shares_in_pool + amount,
                                    winner: false
                                }
                            );
                    }
                } else {
                    if i == outcome_index {
                        self
                            .outcomes
                            .write(
                                (market_id, i),
                                Outcome {
                                    name: outcome.name,
                                    num_shares_in_pool: shares_in_pool + shares_updated - amount,
                                    winner: false
                                }
                            );
                    } else {
                        self
                            .outcomes
                            .write(
                                (market_id, i),
                                Outcome {
                                    name: outcome.name,
                                    num_shares_in_pool: shares_in_pool - amount,
                                    winner: false
                                }
                            );
                    }
                }
                i += 1;
            };
        }
    }
}
