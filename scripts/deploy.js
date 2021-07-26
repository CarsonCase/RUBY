// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy

  // BUNNY
  const Bunny = await hre.ethers.getContractFactory("BunnyToken");
  const bunny = await Bunny.deploy();

  await bunny.deployed();

  console.log("Bunny token deployed to:", bunny.address);

  // BUNNY POOL
  const BunnyPool = await hre.ethers.getContractFactory("BunnyPool");
  const bunnyPool = await BunnyPool.deploy(bunny.address);

  await bunnyPool.deployed();

  console.log("Bunny pool deployed to:", bunnyPool.address);
  
  // BUNNY MINTER
  const BunnyMinter = await hre.ethers.getContractFactory("BunnyMinterV2");
  const bunnyMinter = await BunnyMinter.deploy(bunny.address,bunnyPool.address);

  await bunnyMinter.deployed();

  console.log("Bunny pool deployed to:", bunnyMinter.address);
  
  //BUNNY FLIP-FLIP
  const Flip = await hre.ethers.getContractFactory("VaultFlipToFlip");
  const flip = await BunnyMinter.deploy();

  await flip.deployed();

  console.log("Bunny pool deployed to:", flip.address);

  //Bunny bnb requres the Lp token
  //But can be deployed as is
  

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
