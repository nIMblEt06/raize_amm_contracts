use core::option::OptionTrait;
use core::fmt::Display;
use core::traits::AddEq;
use snforge_std::{
    declare, start_mock_call, start_cheat_caller_address, stop_cheat_caller_address,
    ContractClassTrait
};
use starknet::{
    ContractAddress, contract_address_const, get_caller_address, get_contract_address,
    contract_address
};
use raize_amm_contracts::FPMMMarketMaker::{IMarketMakerDispatcher, IMarketMakerDispatcherTrait};
use raize_amm_contracts::FPMMMarketMaker::{Outcome, FPMMMarket};
use raize_amm_contracts::erc20::erc20_mocks::{CamelERC20Mock};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use core::fmt::Debug;
use core::traits::Into;
use core::traits::TryInto;
use core::result::{ResultTrait};
use openzeppelin::utils::serde::SerializedAppend;
use core::pedersen::pedersen;
use starknet::testing::{set_contract_address, set_caller_address};
use core::starknet::SyscallResultTrait;
const PRECISION: u256 = 1_000_000_000_000_000_000;

fn deploy_token() -> ContractAddress {
    let erc20_class_hash = declare("CamelERC20Mock").unwrap();
    let mut calldata = array![];
    let (contract_address, _) = erc20_class_hash.deploy(@calldata).unwrap();
    contract_address
}

fn fakeERCDeployment() -> ContractAddress {
    let erc20 = deploy_token();
    erc20
}

fn deployMarketContract(tokenAddress: ContractAddress) -> ContractAddress {
    let contract = declare("FixedProductMarketMaker").unwrap();
    let mut calldata = array![];
    calldata.append_serde(tokenAddress);
    calldata.append_serde(2);
    let (contract_deploy_address, _) = contract.deploy(@calldata).unwrap();
    contract_deploy_address
}

// should create a market
#[test]
fn createMarket() {
    let tokenAddress = fakeERCDeployment();
    let marketContract = deployMarketContract(tokenAddress);

    let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

    let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };

    start_cheat_caller_address(marketContract, contract_address_const::<1>());

    start_cheat_caller_address(tokenAddress, contract_address_const::<1>());
    tokenDispatcher.approve(marketContract, 10000000);
    stop_cheat_caller_address(tokenAddress);

    dispatcher.add_funding(1000000);

    let mut outcomes: Array<felt252> = ArrayTrait::new();

    outcomes.append('Yes');
    outcomes.append('No');
    outcomes.append('Draw');

    dispatcher.init_market(outcomes, 2048704106);
    let num_markets = dispatcher.get_num_markets();

    assert(num_markets == 1, 'market should be created!');
}


// should add money in main liquidity pool for whatever amount is added per market
#[test]
fn shouldAddMoney() {
    let tokenAddress = fakeERCDeployment();
    let marketContract = deployMarketContract(tokenAddress);

    let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

    let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };

    start_cheat_caller_address(marketContract, contract_address_const::<1>());

    start_cheat_caller_address(tokenAddress, contract_address_const::<1>());
    tokenDispatcher.approve(marketContract, 10000000);
    stop_cheat_caller_address(tokenAddress);

    dispatcher.add_funding(1000000);

    let currentLiquidity = dispatcher.current_liquidity();

    println!("Current liquidity: {}", currentLiquidity);

    assert(currentLiquidity > 0, 'liquidity should be added!');
}

// should add money in main liquidity pool for whatever amount is added per market
#[test]
fn shouldRemoveMoney() {
    let tokenAddress = fakeERCDeployment();
    let marketContract = deployMarketContract(tokenAddress);

    let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

    let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };

    start_cheat_caller_address(marketContract, contract_address_const::<1>());

    start_cheat_caller_address(tokenAddress, contract_address_const::<1>());
    tokenDispatcher.approve(marketContract, 10000000);
    stop_cheat_caller_address(tokenAddress);

    dispatcher.add_funding(1000000);

    dispatcher.remove_funding(10000);

    let currentLiquidity = dispatcher.current_liquidity();

    println!("Current liquidity: {}", currentLiquidity);

    assert(currentLiquidity == 1000000 - 10000, 'liquidity should be removed!');
}

// should take bets
#[test]
fn shouldAcceptBets() {
    let tokenAddress = fakeERCDeployment();
    let marketContract = deployMarketContract(tokenAddress);

    let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

    let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };

    start_cheat_caller_address(marketContract, contract_address_const::<1>());

    start_cheat_caller_address(tokenAddress, contract_address_const::<1>());
    tokenDispatcher.approve(marketContract, 100000000);
    stop_cheat_caller_address(tokenAddress);

    dispatcher.add_funding(1000000);

    let mut outcomes: Array<felt252> = ArrayTrait::new();

    outcomes.append('Yes');
    outcomes.append('No');
    outcomes.append('Draw');

    dispatcher.init_market(outcomes, 2048704106);

    let min_amount = dispatcher.calc_buy_amount(1, 10000, 1);

    dispatcher.buy(1, 10000, 1, min_amount);
}

// // should change odds after every bet
// #[test]
// fn shouldChangeOdds() {
//     let tokenAddress = fakeERCDeployment();
//     let marketContract = deployMarketContract(tokenAddress);

//     let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

//     let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };
// }


// should let people sell their shares
#[test]
fn shouldLetPersonSell() {
    let tokenAddress = fakeERCDeployment();
    let marketContract = deployMarketContract(tokenAddress);

    let dispatcher = IMarketMakerDispatcher { contract_address: marketContract };

    let tokenDispatcher = IERC20Dispatcher { contract_address: tokenAddress };

    start_cheat_caller_address(marketContract, contract_address_const::<1>());

    start_cheat_caller_address(tokenAddress, contract_address_const::<1>());
    tokenDispatcher.approve(marketContract, 100000000);
    stop_cheat_caller_address(tokenAddress);

    dispatcher.add_funding(1000000);

    let mut outcomes: Array<felt252> = ArrayTrait::new();

    outcomes.append('Yes');
    outcomes.append('No');
    outcomes.append('Draw');

    dispatcher.init_market(outcomes, 2048704106);

    let min_amount = dispatcher.calc_buy_amount(1, 10000, 1);

    dispatcher.buy(1, 10000, 1, min_amount);

    let min_sell_amount = dispatcher.calc_sell_amount(1, 10000, 1);

    dispatcher.sell(1, 4000, 1, min_sell_amount);
}

