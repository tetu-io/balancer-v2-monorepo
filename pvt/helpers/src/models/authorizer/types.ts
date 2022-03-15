import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';

export type TimelockAuthorizerDeployment = {
  admin?: SignerWithAddress;
  from?: SignerWithAddress;
};
