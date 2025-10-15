# aurora-minimal-production
Minimal production repo for `Staking => StakingPool` smart contract flow issue

`Staking` contract:
- Please check the `stake / stakeMultiple` methods, we always `lock` on when running these methods (we don't run `lock` on it's own)
- Please check the `unstake / unstakeMultiple` methods, we always `unlock` on when running these methods (we don't run `unlock` on it's own)
- Please check the `claim / claimMultiple` methods, these methods call a shady `_claimStakingaCO2` method in `StakingPool` contract, which is the root of the issue since it has an inefficient gas usage pattern, we believe it's because of the `while` loop in the `_claimStakingaCO2` method of `StakingPool` contract

`StakingPool` contract:
- Please check the `_claimStakingaCO2` method and the `while` loop inside it, we believe this is the root of the issue since it has an inefficient gas usage pattern. Also any refactors or suggestions to improve the gas usage of this method would be greatly appreciated.

# Important Note:
Please make sure to create a `.env` file in the root directory with the following content:
PRIVATE_KEY=your_private_key_here (can be any random string for testing purposes)

- We have already created V2 of these contracts with improved gas usage patterns, but they are still in draft phase and we have not even unit tested them yet, they are also included, so maybe you can take a look at them as well and see if these changes make sense or if you have any suggestions to improve them further.
