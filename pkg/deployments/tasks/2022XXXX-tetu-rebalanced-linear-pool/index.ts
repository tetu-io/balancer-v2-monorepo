import Task from '../../src/task';
import { TaskRunOptions } from '../../src/types';
import { AaveLinearPoolDeployment } from './input';

export default async (task: Task, { force, from }: TaskRunOptions = {}): Promise<void> => {
  const input = task.input() as AaveLinearPoolDeployment;
  const args = [input.Vault, input.ProtocolFeePercentagesProvider, input.BalancerQueries];
  console.log(`input.Vault ${input.Vault}`);
  console.log(`input.ProtocolFeePercentagesProvider ${input.ProtocolFeePercentagesProvider}`);
  console.log(`input.BalancerQueries ${input.BalancerQueries}`);
  await task.deployAndVerify('TetuLinearPoolFactory', args, from, force);
};
