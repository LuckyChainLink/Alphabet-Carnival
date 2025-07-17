import { expect } from "chai";
import { ethers, network } from "hardhat";
import { MerkleTree } from "merkletreejs";
import keccak256 from "keccak256";
import { AlphabetCarnival, VRFCoordinatorV2_5Mock } from "../typechain-types";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("AlphabetCarnival - VRF v2.5 & Merkle Proofs", function () {
  let alphabetCarnival: AlphabetCarnival;
  let vrfCoordinatorMock: VRFCoordinatorV2_5Mock;
  let owner: HardhatEthersSigner,
    player1: HardhatEthersSigner,
    player2: HardhatEthersSigner,
    operationalReceiver1: HardhatEthersSigner,
    operationalReceiver2: HardhatEthersSigner;
  let subscriptionId: bigint;

  const TICKET_PRICE = ethers.parseEther("0.0008");
  const TICKETS_THRESHOLD = 50n;
  const LINK_FUND_AMOUNT = ethers.parseEther("10");
  const KEY_HASH =
    "0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4";
  const CALLBACK_GAS_LIMIT = 500000;

  beforeEach(async function () {
    [
      owner,
      player1,
      player2,
      operationalReceiver1,
      operationalReceiver2,
    ] = await ethers.getSigners();

    // 1. 部署 Chainlink VRF v2.5 模拟器
    const VRFCoordinatorV2_5MockFactory = await ethers.getContractFactory(
      "VRFCoordinatorV2_5Mock"
    );
    vrfCoordinatorMock = await VRFCoordinatorV2_5MockFactory.deploy(
      ethers.parseEther("0.1"),
      1e9
    );
    const vrfCoordinatorAddress = await vrfCoordinatorMock.getAddress();

    // 2. 创建 VRF 订阅
    const createSubTx = await vrfCoordinatorMock.createSubscription();
    const createSubReceipt = await createSubTx.wait();
    if (!createSubReceipt?.logs) throw new Error("Subscription creation failed");
    subscriptionId = (createSubReceipt.logs[0] as any).args.subId;


    // 3. 给订阅充值
    await vrfCoordinatorMock.fundSubscription(subscriptionId, LINK_FUND_AMOUNT);

    // 4. 部署 AlphabetCarnival 合约
    const AlphabetCarnivalFactory = await ethers.getContractFactory(
      "AlphabetCarnival"
    );
    alphabetCarnival = await AlphabetCarnivalFactory.deploy(
      vrfCoordinatorAddress,
      KEY_HASH,
      CALLBACK_GAS_LIMIT,
      subscriptionId,
      operationalReceiver1.address,
      operationalReceiver2.address,
      50, // 50% for receiver 1
      TICKET_PRICE,
      TICKETS_THRESHOLD
    );
    await alphabetCarnival.waitForDeployment();
    const alphabetCarnivalAddress = await alphabetCarnival.getAddress();

    // 5. 将合约添加为消费者
    await vrfCoordinatorMock.addConsumer(
      subscriptionId,
      alphabetCarnivalAddress
    );
  });

  describe("Full Game Flow", function () {
    it("should trigger a draw, fulfill randomness, submit Merkle root, and allow prize claims", async function () {
      const roundToTest = 1;

      // --- 步骤 1: 玩家购票直到触发开奖 ---
      const ticketsToBuy = Number(TICKETS_THRESHOLD);
      for (let i = 0; i < ticketsToBuy -1; i++) {
        let chosenLetters: [number, number, number] = [1, (i % 25) + 2, (i % 24) + 3];
        chosenLetters.sort((a, b) => a - b);
        await alphabetCarnival
          .connect(player1)
          .buyTicket(chosenLetters, { value: TICKET_PRICE });
      }

      // 购买最后一张票来触发开奖
      const prizePoolForRound1 = TICKET_PRICE * BigInt(ticketsToBuy);
      const lastTicketTx = await alphabetCarnival.connect(player2).buyTicket([10,11,12], {value: TICKET_PRICE});
      
      const requestIdFilter = alphabetCarnival.filters.DrawTriggeredAndRandomnessRequested(BigInt(roundToTest));
      const events = await alphabetCarnival.queryFilter(requestIdFilter, lastTicketTx.blockNumber);
      const requestId = events[0].args.requestId;
      expect(requestId).to.not.equal(0);
      

      // --- 步骤 2: 模拟 VRF 回调 ---
      await expect(
        vrfCoordinatorMock.fulfillRandomWords(
          requestId,
          await alphabetCarnival.getAddress()
        )
      ).to.emit(alphabetCarnival, "WinningLettersDrawn");

      // 验证开奖后状态
      expect(await alphabetCarnival.s_isRequestPending()).to.be.false;
      expect(await alphabetCarnival.currentRound()).to.equal(roundToTest + 1);
      expect(await alphabetCarnival.prizePool()).to.equal(0);

      // --- 步骤 3: 链下计算并提交 Merkle Root ---
      const mockWinnersData = [
        { player: player1.address, chosenLetters: [1, 2, 3], prizeLevel: 1, prizeAmount: ethers.parseEther("0.1"), round: roundToTest },
        { player: player2.address, chosenLetters: [10, 11, 12], prizeLevel: 2, prizeAmount: ethers.parseEther("0.05"), round: roundToTest }
      ];

      const leaves = mockWinnersData.map(data =>
        keccak256(
          ethers.AbiCoder.defaultAbiCoder().encode(
            ["address", "uint8[3]", "uint8", "uint256", "uint256"],
            [data.player, [Number(data.chosenLetters[0]), Number(data.chosenLetters[1]), Number(data.chosenLetters[2])], data.prizeLevel, data.prizeAmount, data.round]
          )
        )
      );

      const merkleTree = new MerkleTree(leaves, keccak256, {
        sortPairs: true,
      });
      const merkleRoot = merkleTree.getHexRoot();

      await expect(
        alphabetCarnival
          .connect(owner)
          .submitWinnersMerkleRoot(roundToTest, merkleRoot, prizePoolForRound1)
      ).to.emit(alphabetCarnival, "MerkleRootSubmitted")
        .withArgs(roundToTest, merkleRoot);
      
      expect(await alphabetCarnival.roundMerkleRoots(roundToTest)).to.equal(merkleRoot);

      // --- 步骤 4: 玩家领取奖金 ---
      // Player 1 领奖
      const claimData1 = mockWinnersData[0];
      const proof1 = merkleTree.getHexProof(leaves[0]);

      await expect(alphabetCarnival.connect(player1).claimPrize(claimData1, proof1))
        .to.emit(alphabetCarnival, "PrizeClaimed")
        .withArgs(claimData1.player, claimData1.round, claimData1.prizeLevel, claimData1.prizeAmount);

      // 验证重复领取失败
      await expect(
        alphabetCarnival.connect(player1).claimPrize(claimData1, proof1)
      ).to.be.revertedWith("Prize already claimed.");
    });
  });
});