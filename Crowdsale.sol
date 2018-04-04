pragma solidity ^0.4.18;

import './fund/ICrowdsaleFund.sol';
import './fund/ICrowdsaleReservationFund.sol';
import './token/IERC20Token.sol';
import './token/TransferLimitedToken.sol';
import './token/LockedTokens.sol';
import './ownership/Ownable.sol';
import './Pausable.sol';
import './ISimpleCrowdsale.sol';


contract TheAbyssDAICO is Ownable, SafeMath, Pausable, ISimpleCrowdsale {
    enum TelegramBonusState {
        Unavailable,
        Active,
        Applied
    }

    uint256 public constant TG_BONUS_NUM = 3;
    uint256 public constant TG_BONUS_DENOM = 100;

    uint256 public constant ETHER_MIN_CONTRIB = 0.1 ether;
    uint256 public constant ETHER_MAX_CONTRIB = 10 ether;

    uint256 public constant ETHER_MIN_CONTRIB_PRIVATE = 100 ether;
    uint256 public constant ETHER_MAX_CONTRIB_PRIVATE = 3000 ether;

    uint256 public constant ETHER_MIN_CONTRIB_USA = 1 ether;
    uint256 public constant ETHER_MAX_CONTRIB_USA = 100 ether;

    uint256 public constant SALE_START_TIME = 1523887200; // 16.04.2018 14:00:00 UTC
    uint256 public constant SALE_END_TIME = 1526479200; // 16.05.2018 14:00:00 UTC

    uint256 public constant BONUS_WINDOW_1_END_TIME = SALE_START_TIME + 2 days;
    uint256 public constant BONUS_WINDOW_2_END_TIME = SALE_START_TIME + 7 days;
    uint256 public constant BONUS_WINDOW_3_END_TIME = SALE_START_TIME + 14 days;
    uint256 public constant BONUS_WINDOW_4_END_TIME = SALE_START_TIME + 21 days;

    uint256 public constant MAX_CONTRIB_CHECK_END_TIME = SALE_START_TIME + 1 days;

    uint256 public constant BNB_TOKEN_PRICE_NUM = 50; // Price will be set right before Token Sale
    uint256 public constant BNB_TOKEN_PRICE_DENOM = 1;

    uint256 public tokenPriceNum = 0;
    uint256 public tokenPriceDenom = 0;
    
    TransferLimitedToken public token;
    ICrowdsaleFund public fund;
    ICrowdsaleReservationFund public reservationFund;
    LockedTokens public lockedTokens;

    mapping(address => bool) public whiteList;
    mapping(address => bool) public privilegedList;
    mapping(address => TelegramBonusState) public telegramMemberBonusState;
    mapping(address => uint256) public userTotalContributed;

    address public bnbTokenWallet;
    address public referralTokenWallet;
    address public developerTokenWallet;
    address public advisorsTokenWallet;
    address public companyTokenWallet;
    address public reserveTokenWallet;
    address public bountyTokenWallet;

    uint256 public totalEtherContributed = 0;
    uint256 public rawTokenSupply = 0;

    // BNB
    IERC20Token public bnbToken;
    uint256 public BNB_HARD_CAP = 300000 ether; // 300K BNB
    uint256 public BNB_MIN_CONTRIB = 1000 ether; // 1K BNB
    mapping(address => uint256) public bnbContributions;
    uint256 public totalBNBContributed = 0;

    uint256 public hardCap = 0; // World hard cap will be set right before Token Sale
    uint256 public softCap = 0; // World soft cap will be set right before Token Sale

    bool public bnbRefundEnabled = false;

    event LogContribution(address contributor, uint256 amountWei, uint256 tokenAmount, uint256 tokenBonus, uint256 timestamp);
    event ReservationFundContribution(address contributor, uint256 amountWei, uint256 tokensToIssue, uint256 bonusTokensToIssue, uint256 timestamp);
    event LogBNBContribution(address contributor, uint256 amountBNB, uint256 tokenAmount, uint256 tokenBonus, uint256 timestamp);

    modifier checkContribution() {
        require(isValidContribution());
        _;
    }

    modifier checkBNBContribution() {
        require(isValidBNBContribution());
        _;
    }

    modifier checkCap() {
        require(validateCap());
        _;
    }

    function TheAbyssDAICO(
        address bnbTokenAddress,
        address tokenAddress,
        address fundAddress,
        address reservationFundAddress,
        address _bnbTokenWallet,
        address _referralTokenWallet,
        address _developerTokenWallet,
        address _advisorsTokenWallet,
        address _companyTokenWallet,
        address _reserveTokenWallet,
        address _bountyTokenWallet,
        address _owner
    ) public
        Ownable(_owner)
    {
        require(tokenAddress != address(0));

        bnbToken = IERC20Token(bnbTokenAddress);
        token = TransferLimitedToken(tokenAddress);
        fund = ICrowdsaleFund(fundAddress);
        reservationFund = ICrowdsaleReservationFund(reservationFundAddress);

        bnbTokenWallet = _bnbTokenWallet;
        referralTokenWallet = _referralTokenWallet;
        developerTokenWallet = _developerTokenWallet;
        advisorsTokenWallet = _advisorsTokenWallet;
        companyTokenWallet = _companyTokenWallet;
        reserveTokenWallet = _reserveTokenWallet;
        bountyTokenWallet = _bountyTokenWallet;
    }

    /**
     * @dev check if address can contribute
     */
    function isContributorInLists(address contributor) external view returns(bool) {
        return whiteList[contributor] || privilegedList[contributor] || token.limitedWallets(contributor);
    }

    /**
     * @dev check contribution amount and time
     */
    function isValidContribution() internal view returns(bool) {
        if(now < SALE_START_TIME || now > SALE_END_TIME) {
            return false;

        }
        uint256 currentUserContribution = safeAdd(msg.value, userTotalContributed[msg.sender]);
        if(whiteList[msg.sender] && msg.value >= ETHER_MIN_CONTRIB) {
            if(now <= MAX_CONTRIB_CHECK_END_TIME && currentUserContribution > ETHER_MAX_CONTRIB ) {
                    return false;
            }
            return true;

        }
        if(privilegedList[msg.sender] && msg.value >= ETHER_MIN_CONTRIB_PRIVATE) {
            if(now <= MAX_CONTRIB_CHECK_END_TIME && currentUserContribution > ETHER_MAX_CONTRIB_PRIVATE ) {
                    return false;
            }
            return true;
        }

        if(token.limitedWallets(msg.sender) && msg.value >= ETHER_MIN_CONTRIB_USA) {
            if(now <= MAX_CONTRIB_CHECK_END_TIME && currentUserContribution > ETHER_MAX_CONTRIB_USA) {
                    return false;
            }
            return true;
        }

        return false;
    }

    /**
     * @dev Check hard cap overflow
     */
    function validateCap() internal view returns(bool){
        if(msg.value <= safeSub(hardCap, totalEtherContributed)) {
            return true;
        }
        return false;
    }

    /**
     * @dev Set token price once before start of crowdsale
     */
    function setTokenPrice(uint256 _tokenPriceNum, uint256 _tokenPriceDenom) public onlyOwner {
        require(tokenPriceNum == 0 && tokenPriceDenom == 0);
        require(_tokenPriceNum > 0 && _tokenPriceDenom > 0);
        tokenPriceNum = _tokenPriceNum;
        tokenPriceDenom = _tokenPriceDenom;
    }

    /**
     * @dev Set hard cap.
     * @param _hardCap - Hard cap value
     */
    function setHardCap(uint256 _hardCap) public onlyOwner {
        require(hardCap == 0);
        hardCap = _hardCap;
    }

    /**
     * @dev Set soft cap.
     * @param _softCap - Soft cap value
     */
    function setSoftCap(uint256 _softCap) public onlyOwner {
        require(softCap == 0);
        softCap = _softCap;
    }

    /**
     * @dev Get soft cap amount
     **/
    function getSoftCap() external view returns(uint256) {
        return softCap;
    }

    /**
     * @dev Check bnb contribution time, amount and hard cap overflow
     */
    function isValidBNBContribution() internal view returns(bool) {
        if(token.limitedWallets(msg.sender)) {
            return false;
        }
        if(now < SALE_START_TIME || now > SALE_END_TIME) {
            return false;
        }
        if(!whiteList[msg.sender] && !privilegedList[msg.sender]) {
            return false;
        }
        uint256 amount = bnbToken.allowance(msg.sender, address(this));
        if(amount < BNB_MIN_CONTRIB || safeAdd(totalBNBContributed, amount) > BNB_HARD_CAP) {
            return false;
        }
        return true;

    }

    /**
     * @dev Calc bonus amount by contribution time
     */
    function getBonus() internal constant returns (uint256, uint256) {
        uint256 numerator = 0;
        uint256 denominator = 100;

        if(now < BONUS_WINDOW_1_END_TIME) {
            numerator = 25;
        } else if(now < BONUS_WINDOW_2_END_TIME) {
            numerator = 15;
        } else if(now < BONUS_WINDOW_3_END_TIME) {
            numerator = 10;
        } else if(now < BONUS_WINDOW_4_END_TIME) {
            numerator = 5;
        } else {
            numerator = 0;
        }

        return (numerator, denominator);
    }

    /**
     * @dev Add wallet to whitelist. For contract owner only.
     */
    function addToWhiteList(address _wallet) public onlyOwner {
        whiteList[_wallet] = true;
    }

    /**
     * @dev Add wallet to telegram members. For contract owner only.
     */
    function addTelegramMember(address _wallet) public onlyOwner {
        telegramMemberBonusState[_wallet] = TelegramBonusState.Active;
    }

    /**
     * @dev Add wallet to privileged list. For contract owner only.
     */
    function addToPrivilegedList(address _wallet) public onlyOwner {
        privilegedList[_wallet] = true;
    }

    /**
     * @dev Set LockedTokens contract address
     */
    function setLockedTokens(address lockedTokensAddress) public onlyOwner {
        lockedTokens = LockedTokens(lockedTokensAddress);
    }

    /**
     * @dev Fallback function to receive ether contributions
     */
    function () payable public whenNotPaused {
        if(whiteList[msg.sender] || privilegedList[msg.sender] || token.limitedWallets(msg.sender)) {
            processContribution();
        } else {
            processReservationContribution();
        }
    }

    function processReservationContribution() private checkCap {
        require(now >= SALE_START_TIME && now <= SALE_END_TIME);
        require(msg.value >= ETHER_MIN_CONTRIB);

        if(now <= MAX_CONTRIB_CHECK_END_TIME) {
            uint256 currentUserContribution = safeAdd(msg.value, reservationFund.contributionsOf(msg.sender));
            require(currentUserContribution <= ETHER_MAX_CONTRIB);
        }
        uint256 bonusNum = 0;
        uint256 bonusDenom = 100;
        (bonusNum, bonusDenom) = getBonus();
        uint256 tokenBonusAmount = 0;
        uint256 tokenAmount = safeDiv(safeMul(msg.value, tokenPriceNum), tokenPriceDenom);

        if(bonusNum > 0) {
            tokenBonusAmount = safeDiv(safeMul(tokenAmount, bonusNum), bonusDenom);
        }

        reservationFund.processContribution.value(msg.value)(
            msg.sender,
            tokenAmount,
            tokenBonusAmount
        );
        ReservationFundContribution(msg.sender, msg.value, tokenAmount, tokenBonusAmount, now);
    }

    /**
     * @dev Process BNB token contribution
     * Transfer all amount of tokens approved by sender. Calc bonuses and issue tokens to contributor.
     */
    function processBNBContribution() public whenNotPaused checkBNBContribution {
        uint256 bonusNum = 0;
        uint256 bonusDenom = 100;
        (bonusNum, bonusDenom) = getBonus();
        uint256 amountBNB = bnbToken.allowance(msg.sender, address(this));
        bnbToken.transferFrom(msg.sender, address(this), amountBNB);
        bnbContributions[msg.sender] = safeAdd(bnbContributions[msg.sender], amountBNB);

        uint256 tokenBonusAmount = 0;
        uint256 tokenAmount = safeDiv(safeMul(amountBNB, BNB_TOKEN_PRICE_NUM), BNB_TOKEN_PRICE_DENOM);
        rawTokenSupply = safeAdd(rawTokenSupply, tokenAmount);
        if(bonusNum > 0) {
            tokenBonusAmount = safeDiv(safeMul(tokenAmount, bonusNum), bonusDenom);
        }

        if(telegramMemberBonusState[msg.sender] ==  TelegramBonusState.Active) {
            telegramMemberBonusState[msg.sender] = TelegramBonusState.Applied;
            uint256 telegramBonus = safeDiv(safeMul(tokenAmount, TG_BONUS_NUM), TG_BONUS_DENOM);
            tokenBonusAmount = safeAdd(tokenBonusAmount, telegramBonus);
        }

        uint256 tokenTotalAmount = safeAdd(tokenAmount, tokenBonusAmount);
        token.issue(msg.sender, tokenTotalAmount);
        totalBNBContributed = safeAdd(totalBNBContributed, amountBNB);

        LogBNBContribution(msg.sender, amountBNB, tokenAmount, tokenBonusAmount, now);
    }

    /**
     * @dev Process ether contribution. Calc bonuses and issue tokens to contributor.
     */
    function processContribution() private checkContribution checkCap {
        uint256 bonusNum = 0;
        uint256 bonusDenom = 100;
        (bonusNum, bonusDenom) = getBonus();
        uint256 tokenBonusAmount = 0;
        userTotalContributed[msg.sender] = safeAdd(userTotalContributed[msg.sender], msg.value);
        uint256 tokenAmount = safeDiv(safeMul(msg.value, tokenPriceNum), tokenPriceDenom);
        rawTokenSupply = safeAdd(rawTokenSupply, tokenAmount);

        if(bonusNum > 0) {
            tokenBonusAmount = safeDiv(safeMul(tokenAmount, bonusNum), bonusDenom);
        }

        if(telegramMemberBonusState[msg.sender] ==  TelegramBonusState.Active) {
            telegramMemberBonusState[msg.sender] = TelegramBonusState.Applied;
            uint256 telegramBonus = safeDiv(safeMul(tokenAmount, TG_BONUS_NUM), TG_BONUS_DENOM);
            tokenBonusAmount = safeAdd(tokenBonusAmount, telegramBonus);
        }

        processPayment(msg.sender, msg.value, tokenAmount, tokenBonusAmount);
    }

    function processReservationFundContribution(
        address contributor,
        uint256 tokenAmount,
        uint256 tokenBonusAmount
    ) external payable checkCap {
        require(msg.sender == address(reservationFund));
        require(msg.value > 0);

        processPayment(contributor, msg.value, tokenAmount, tokenBonusAmount);
    }

    function processPayment(address contributor, uint256 etherAmount, uint256 tokenAmount, uint256 tokenBonusAmount) internal {
        uint256 tokenTotalAmount = safeAdd(tokenAmount, tokenBonusAmount);

        token.issue(contributor, tokenTotalAmount);
        fund.processContribution.value(etherAmount)(contributor);
        totalEtherContributed = safeAdd(totalEtherContributed, etherAmount);

        LogContribution(contributor, etherAmount, tokenAmount, tokenBonusAmount, now);
    }

    /**
     * @dev Finalize crowdsale if we reached hard cap or current time > SALE_END_TIME
     */
    function finalizeCrowdsale() public onlyOwner {
        if(
            (totalEtherContributed >= safeSub(hardCap, ETHER_MIN_CONTRIB_USA) && totalBNBContributed >= safeSub(BNB_HARD_CAP, BNB_MIN_CONTRIB)) ||
            (now >= SALE_END_TIME && totalEtherContributed >= softCap)
        ) {
            fund.onCrowdsaleEnd();
            reservationFund.onCrowdsaleEnd();
            // BNB transfer
            bnbToken.transfer(bnbTokenWallet, bnbToken.balanceOf(address(this)));

            // Referral
            uint256 referralTokenAmount = safeDiv(rawTokenSupply, 10);
            token.issue(referralTokenWallet, referralTokenAmount);

            // Developer
            uint256 developerTokenAmount = safeDiv(token.totalSupply(), 2);
            lockedTokens.addTokens(developerTokenWallet, developerTokenAmount, now + 365 days);

            uint256 suppliedTokenAmount = token.totalSupply();

            // Reserve
            uint256 reservedTokenAmount = safeDiv(safeMul(suppliedTokenAmount, 3), 10); // 18%
            token.issue(address(lockedTokens), reservedTokenAmount);
            lockedTokens.addTokens(reserveTokenWallet, reservedTokenAmount, now + 183 days);

            // Advisors
            uint256 advisorsTokenAmount = safeDiv(suppliedTokenAmount, 10); // 6%
            token.issue(advisorsTokenWallet, advisorsTokenAmount);

            // Company
            uint256 companyTokenAmount = safeDiv(suppliedTokenAmount, 4); // 15%
            token.issue(address(lockedTokens), companyTokenAmount);
            lockedTokens.addTokens(companyTokenWallet, companyTokenAmount, now + 730 days);


            // Bounty
            uint256 bountyTokenAmount = safeDiv(suppliedTokenAmount, 60); // 1%
            token.issue(bountyTokenWallet, bountyTokenAmount);

            token.setAllowTransfers(true);

        } else if(now >= SALE_END_TIME) {
            // Enable fund`s crowdsale refund if soft cap is not reached
            fund.enableCrowdsaleRefund();
            reservationFund.onCrowdsaleEnd();
            bnbRefundEnabled = true;
        }
        token.finishIssuance();
    }

    /**
     * @dev Function is called by contributor to refund BNB token payments if crowdsale failed to reach soft cap
     */
    function refundBNBContributor() public {
        require(bnbRefundEnabled);
        require(bnbContributions[msg.sender] > 0);
        uint256 amount = bnbContributions[msg.sender];
        bnbContributions[msg.sender] = 0;
        bnbToken.transfer(msg.sender, amount);
        token.destroy(msg.sender, token.balanceOf(msg.sender));
    }
}
