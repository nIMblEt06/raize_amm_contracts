// Cairo contract for prediction markets, using Fixed Product Market Making (FPMM).
// We wish to create markets in a way so that the names/descriptions are done on a backend service, and the contract is only responsible for the market creation and trading.
pub mod FPMMMarketMaker;
pub mod erc20;
#[cfg(test)]
mod tests;
