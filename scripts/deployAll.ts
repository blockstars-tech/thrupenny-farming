import { BigNumber } from "ethers";
import fs from "fs";
import hre, { ethers, network } from "hardhat";
import { hoursToSeconds, getNextTimestampDivisibleBy, minutesToSeconds } from "./helpers/utils";

const verifyContract = async (contractAddress: string, constructorArguments: Array<any>) => {
  const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  try {
    const tx = await hre.run("verify:verify", {
      address: contractAddress,
      constructorArguments,
    });
    console.log(tx);

    await sleep(16000);
  } catch (error) {
    console.log("error is ->");
    console.log(error);
    console.log("cannot verify contract", contractAddress);
    await sleep(16000);
  }
  console.log("contract", contractAddress, "verified successfully");
};

const ten = BigNumber.from(10);
const tenPow18 = ten.pow(18);
const fakeMonth = minutesToSeconds(BigNumber.from(7)); // 1 hour

const main = async () => {
  const FakeToken = await ethers.getContractFactory("FakeERC20");
  const StrategyMock = await ethers.getContractFactory("StrategyMock");
  const Farming = await ethers.getContractFactory("NewFarming");

  const startTime = await getNextTimestampDivisibleBy(fakeMonth.toNumber());

  const fakeRewardToken = await FakeToken.deploy("FakeRewardToken", "FakeRewardToken");
  const fakeStakingToken = await FakeToken.deploy("FakeStakingToken", "FakeStakingToken");
  await fakeRewardToken.deployed();
  await fakeStakingToken.deployed();

  const farming = await Farming.deploy(
    fakeRewardToken.address,
    fakeStakingToken.address,
    startTime
  );
  await farming.deployed();

  const fakeStrategy = await StrategyMock.deploy(fakeStakingToken.address, farming.address);
  await fakeStrategy.deployed();

  await farming.setStrategy(fakeStrategy.address);

  const addresses = {
    fakeRewardToken: fakeRewardToken.address,
    fakeStakingToken: fakeStakingToken.address,
    farming: farming.address,
    fakeStrategy: fakeStrategy.address,
  };
  const jsonAddresses = JSON.stringify(addresses);
  fs.writeFileSync(`./addresses/${network.name}Addresses.json`, jsonAddresses);
  console.log("Addresses saved!");

  await verifyContract(fakeRewardToken.address, ["FakeRewardToken", "FakeRewardToken"]);
  await verifyContract(fakeStakingToken.address, ["FakeStakingToken", "FakeStakingToken"]);
  await verifyContract(farming.address, [
    fakeRewardToken.address,
    fakeStakingToken.address,
    startTime,
  ]);
  await verifyContract(fakeStrategy.address, [fakeRewardToken.address, farming.address]);
};

main()
  .then(() => {
    console.log("Success");
  })
  .catch((err) => {
    console.log(err);
  });
