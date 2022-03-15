import { ethers } from 'hardhat';
import { deploy } from '../../contract';
import { TimelockAuthorizerDeployment } from './types';

import TimelockAuthorizer from './TimelockAuthorizer';
import TypesConverter from '../types/TypesConverter';

export default {
  async deploy(deployment: TimelockAuthorizerDeployment): Promise<TimelockAuthorizer> {
    const admin = deployment.admin || deployment.from || (await ethers.getSigners())[0];
    const instance = await deploy('TimelockAuthorizer', { args: [TypesConverter.toAddress(admin)] });
    return new TimelockAuthorizer(instance, admin);
  },
};
